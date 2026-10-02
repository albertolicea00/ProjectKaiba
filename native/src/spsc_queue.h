#ifndef KAIBA_SPSC_QUEUE_H
#define KAIBA_SPSC_QUEUE_H

#include <atomic>
#include <cstddef>

namespace kaiba {

/// Fixed-capacity, lock-free, wait-free ring buffer for exactly one producer thread and
/// exactly one consumer thread.
///
/// Project Kaiba uses it to carry parsed duel events from the DuelThread (producer) to
/// Godot's main thread (consumer). The main thread must never take a lock to read events:
/// a contended mutex on the render thread is a dropped frame.
///
/// ## Contract
///
/// - Exactly ONE thread may call push(). Exactly ONE (different) thread may call pop().
///   Two producers or two consumers corrupt the buffer silently. There is no runtime check.
/// - size(), empty() and full() are advisory. Between the read and the next statement the
///   other thread may have changed the answer. Only the producer's own full() and the
///   consumer's own empty() are actionable, and even those only in the safe direction
///   (an item can appear after empty() returned true; a slot can free after full() did).
/// - Capacity must be a power of two so the index wrap is a mask instead of a modulo.
///   One slot is reserved to distinguish "full" from "empty", so the usable capacity is
///   Capacity - 1.
///
/// ## Element lifetime
///
/// Slots are default-constructed once, when the queue is constructed, and live until the
/// queue is destroyed. push() copy-assigns into a slot; pop() copy-assigns out of one.
/// Neither allocates a node, and neither takes a lock.
///
/// pop() deliberately does NOT clear the slot it read from. For a refcounted element such
/// as godot::Dictionary this means the queue keeps one extra reference to a drained value
/// until the producer wraps around and overwrites that slot. That retention is bounded by
/// Capacity and costs nothing on the hot path; clearing instead would mean constructing a
/// fresh empty element on every pop, which for godot::Dictionary is a heap allocation on
/// the main thread. Call reset() on a quiesced queue if the references must be dropped
/// eagerly.
///
/// Copy assignment is used rather than move assignment on purpose: godot-cpp's
/// `Dictionary::operator=(Dictionary&&)` constructs over the destination without running
/// its destructor first, which leaks a reference. The copy-assignment overload destroys
/// the old value correctly.
///
/// ## Memory ordering
///
/// Two indices, each written by exactly one thread:
///
///   tail_  written only by the producer, read by both.
///   head_  written only by the consumer, read by both.
///
/// A thread reads its OWN index with memory_order_relaxed. No synchronisation is needed
/// there: it is the only writer, so program order already guarantees it observes its own
/// last store.
///
/// A thread reads the OTHER thread's index with memory_order_acquire, and publishes its
/// own index with memory_order_release. That gives two release/acquire pairs:
///
///   1. producer's `tail_.store(release)`  ->  consumer's `tail_.load(acquire)`
///      The consumer cannot observe the new tail without also observing the slot write
///      that preceded it. This is what makes reading the payload safe instead of a data
///      race on a half-written element.
///
///   2. consumer's `head_.store(release)`  ->  producer's `head_.load(acquire)`
///      The producer cannot observe the freed slot without also observing that the
///      consumer finished reading it. This is what stops the producer from overwriting
///      an element the consumer is still copying out of.
///
/// Dropping either acquire to relaxed would still "work" on x86, where loads already have
/// acquire semantics, and would race on arm64 — which is the primary target. Hence the
/// explicit ordering on every access rather than a blanket memory_order_seq_cst, which
/// would emit a full barrier (dmb ish) per operation for no added guarantee here.
///
/// head_ and tail_ sit in separate cache lines. Sharing one line would make every producer
/// store invalidate the consumer's copy of the index it polls, turning a lock-free queue
/// into a cache-line ping-pong.
template <typename T, std::size_t Capacity = 1024>
class SpscQueue {
	static_assert(Capacity >= 2, "SpscQueue needs at least two slots (one is reserved)");
	static_assert((Capacity & (Capacity - 1)) == 0, "SpscQueue capacity must be a power of two");

public:
	SpscQueue() = default;
	SpscQueue(const SpscQueue &) = delete;
	SpscQueue &operator=(const SpscQueue &) = delete;

	/// Producer side. Returns false when the queue is full; the caller decides whether to
	/// retry, block or drop. Never allocates, never blocks.
	bool push(const T &value) {
		const std::size_t tail = tail_.load(std::memory_order_relaxed);
		const std::size_t next = (tail + 1) & MASK;

		// Acquire: pairs with the consumer's release store of head_. Without it the slot
		// write below could be reordered ahead of the check and clobber an element the
		// consumer is still reading.
		if (next == head_.load(std::memory_order_acquire)) {
			return false;
		}

		slots_[tail] = value;

		// Release: publishes the slot write. Everything written before this store is
		// visible to any thread that observes this value of tail_ with acquire.
		tail_.store(next, std::memory_order_release);
		return true;
	}

	/// Consumer side. Returns false when the queue is empty. Never allocates, never blocks.
	bool pop(T &out) {
		const std::size_t head = head_.load(std::memory_order_relaxed);

		// Acquire: pairs with the producer's release store of tail_, so the slot read
		// below cannot observe a partially written element.
		if (head == tail_.load(std::memory_order_acquire)) {
			return false;
		}

		out = slots_[head];

		// Release: tells the producer the slot is free, and orders the read above before
		// that announcement.
		head_.store((head + 1) & MASK, std::memory_order_release);
		return true;
	}

	/// Advisory. Only meaningful to the consumer, and only as "there was nothing then".
	bool empty() const {
		return head_.load(std::memory_order_acquire) == tail_.load(std::memory_order_acquire);
	}

	/// Advisory. Only meaningful to the producer, and only as "there was no room then".
	bool full() const {
		const std::size_t next = (tail_.load(std::memory_order_acquire) + 1) & MASK;
		return next == head_.load(std::memory_order_acquire);
	}

	/// Advisory snapshot of the number of readable elements.
	std::size_t size() const {
		const std::size_t tail = tail_.load(std::memory_order_acquire);
		const std::size_t head = head_.load(std::memory_order_acquire);
		return (tail - head) & MASK;
	}

	/// Largest number of elements the queue can hold at once.
	static constexpr std::size_t capacity() { return Capacity - 1; }

	/// Drops every pending element and releases the references held by drained slots.
	///
	/// NOT concurrency safe: both threads must be quiesced. Project Kaiba only calls this
	/// between duels, after the worker thread has been joined.
	void reset() {
		for (std::size_t i = 0; i < Capacity; ++i) {
			slots_[i] = T();
		}
		head_.store(0, std::memory_order_relaxed);
		tail_.store(0, std::memory_order_relaxed);
	}

private:
	static constexpr std::size_t MASK = Capacity - 1;

	// 64 bytes is the cache line on arm64 (Apple silicon uses 128 for some caches, but 64
	// is the portable floor and already separates the two indices).
	static constexpr std::size_t CACHE_LINE = 64;

	T slots_[Capacity];

	alignas(CACHE_LINE) std::atomic<std::size_t> head_{ 0 }; // consumer owns the writes
	alignas(CACHE_LINE) std::atomic<std::size_t> tail_{ 0 }; // producer owns the writes
};

} // namespace kaiba

#endif // KAIBA_SPSC_QUEUE_H
