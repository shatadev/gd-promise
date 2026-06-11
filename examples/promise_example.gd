# example.gd
# A guided tour of gd-promise. Attach this script to any Node in an empty
# scene and run it — every demo prints what it's doing and why.
#
# The demos run sequentially so the output reads top to bottom. Each one is
# self-contained; feel free to copy any function into your own project as a
# starting point.

extends Node

signal loot_dropped(item)


func _ready() -> void:
	_demo_synchronous() # deliberately NOT awaited — see section 0
	await _demo_basics()
	await _demo_chaining()
	await _demo_error_handling()
	await _demo_finally()
	await _demo_await_styles()
	await _demo_combinators()
	await _demo_each_and_fold()
	await _demo_retry()
	await _demo_timeout()
	await _demo_from_signal()
	await _demo_cancellation()
	await _demo_cancellation_gotcha()
	print("\n=== All demos finished ===")


# ---------------------------------------------------------------------------
# 0. No await required — promises in plain synchronous functions
# ---------------------------------------------------------------------------
func _demo_synchronous() -> void:
	print("\n--- 0. Synchronous usage (this function contains no await) ---")

	# Creating, chaining, and consuming via callbacks is ordinary synchronous
	# code. This function is NOT a coroutine and returns like any other —
	# ideal for signal handlers, _process, button callbacks, anywhere.
	var p := Promise.new_promise(func(resolve): resolve.call(10))
	p.and_then(func(v): return v * 2) \
		.and_then(func(v): print("callback-style result (ran inline): ", v))

	# Async work is fine here too: attach callbacks and move on. This
	# function returns immediately; the callback fires ~50ms later while the
	# rest of the demos are already running — watch for it below:
	Promise.delay(0.05).and_then(func(_t):
		print("   >>> fire-and-forget callback from section 0, arriving late <<<")
	)

	# `await` belongs only to the OTHER consumption style — suspending the
	# current function via await_status()/await_result()/expect(). In
	# GDScript, a function becomes a coroutine simply by containing an await;
	# the demos below use it to keep their printed output in order, not
	# because the library needs it.


# ---------------------------------------------------------------------------
# 1. Basics — creating and consuming a promise
# ---------------------------------------------------------------------------
func _demo_basics() -> void:
	print("\n--- 1. Basics ---")

	# The executor receives (resolve, reject, on_cancel). Declare only the
	# parameters you need — extras are simply not passed.
	var p := Promise.new_promise(func(resolve):
		resolve.call("hello world")
	)
	p.and_then(func(v): print("resolved with: ", v))

	# Already-settled constructors:
	Promise.resolve(42).and_then(func(v): print("Promise.resolve gave us: ", v))

	# Promises are eager: the executor runs immediately. Use defer() to start
	# work on the next frame instead.
	var deferred := Promise.defer(func(resolve): resolve.call("ran next frame"))
	var r: Array = await deferred.await_status()
	print("defer: ", r[1])


# ---------------------------------------------------------------------------
# 2. Chaining — values flow through and_then
# ---------------------------------------------------------------------------
func _demo_chaining() -> void:
	print("\n--- 2. Chaining ---")

	# Each and_then receives the previous value. Returning a plain value
	# passes it on; returning a Promise waits for it (adoption).
	var r: Array = await Promise.resolve(2) \
		.and_then(func(v): return v + 3) \
		.and_then(func(v): return Promise.delay(0.05).and_then_return(v * 2)) \
		.tap(func(v): print("tap sees %s but doesn't change it" % v)) \
		.await_status()
	print("chain result: ", r[1]) # (2 + 3) * 2 = 10


# ---------------------------------------------------------------------------
# 3. Error handling — reject, catch, recover
# ---------------------------------------------------------------------------
func _demo_error_handling() -> void:
	print("\n--- 3. Error handling ---")

	# catch() handles a rejection; its return value RESOLVES the chain
	# (recovery). Return Promise.reject(...) from inside to stay rejected.
	var recovered: Array = await Promise.reject("disk on fire") \
		.catch(func(reason): return "recovered from: %s" % reason) \
		.await_status()
	print(recovered[1])

	# A rejection nobody handles prints an "Unhandled Promise rejection"
	# warning on the next frame — always end chains with catch() or await
	# them, like this:
	var failed: Array = await Promise.reject("expected failure").await_status()
	print("await_status reports: status=%s reason=%s" %
			[Promise.Status.keys()[failed[0]], failed[1]])


# ---------------------------------------------------------------------------
# 4. finally — cleanup that always runs
# ---------------------------------------------------------------------------
func _demo_finally() -> void:
	print("\n--- 4. finally ---")

	# finally_cb runs on resolve, reject, OR cancel. The handler receives the
	# Status; its return value is DISCARDED and the original outcome passes
	# through to the next link. Perfect for hiding spinners, freeing handles.
	var r: Array = await Promise.resolve("payload") \
	.finally_cb(func(status):
		print("cleanup ran (status was %s)" % Promise.Status.keys()[status])
	) \
	.await_status()
	print("value survived finally untouched: ", r[1])

	# Because finally passes REJECTIONS through too, a rejecting chain still
	# needs a catch after (or around) it:
	await Promise.reject("oops") \
		.finally_cb(func(_s): print("cleanup runs on rejection too")) \
		.catch(func(reason): print("...and the rejection (%s) flows on" % reason)) \
		.await_status()


# ---------------------------------------------------------------------------
# 5. Awaiting — three styles
# ---------------------------------------------------------------------------
func _demo_await_styles() -> void:
	print("\n--- 5. Awaiting ---")

	var p := Promise.delay(0.05).and_then_return("done")

	# [Status, value] — distinguishes rejection from cancellation:
	var s: Array = await p.await_status()
	print("await_status -> [%s, %s]" % [Promise.Status.keys()[s[0]], s[1]])

	# [resolved_bool, value] — when you only care about success/failure:
	var ok: Array = await p.await_result()
	print("await_result -> ", ok)

	# expect() — returns the value, push_error's on rejection/cancellation.
	# Use it for promises that genuinely must succeed.
	var v: Variant = await Promise.resolve("guaranteed").expect()
	print("expect -> ", v)


# ---------------------------------------------------------------------------
# 6. Combinators — all / any / some / race / all_settled
# ---------------------------------------------------------------------------
func _demo_combinators() -> void:
	print("\n--- 6. Combinators ---")

	var fast := func(value, secs): return Promise.delay(secs).and_then_return(value)

	# all: every value, in input order. Rejects on the first rejection
	# (and cancels the rest if nothing else consumes them).
	var all_r: Array = await Promise.all([
		fast.call("a", 0.03), fast.call("b", 0.01), fast.call("c", 0.02)
	]).await_status()
	print("all -> ", all_r[1]) # ["a", "b", "c"] regardless of finish order

	# race: first to SETTLE wins (a fast rejection wins too). Losers with no
	# other consumers are cancelled.
	var race_r: Array = await Promise.race([
		fast.call("tortoise", 0.2), fast.call("hare", 0.01)
	]).await_status()
	print("race -> ", race_r[1])

	# any: first to RESOLVE wins; rejections are tolerated until none remain.
	var any_r: Array = await Promise.any([
		Promise.reject("nope"), fast.call("survivor", 0.02)
	]).await_status()
	print("any -> ", any_r[1])

	# all_settled: never rejects; reports every fate as a Status.
	var settled: Array = await Promise.all_settled([
		Promise.resolve(1), Promise.reject("e")
	]).await_status()
	var names := []
	for status in settled[1]:
		names.append(Promise.Status.keys()[status])
	print("all_settled -> ", names)


# ---------------------------------------------------------------------------
# 7. each / fold — serial async iteration
# ---------------------------------------------------------------------------
func _demo_each_and_fold() -> void:
	print("\n--- 7. each / fold ---")

	# each runs the predicate one element at a time, waiting for any Promise
	# it returns before moving on. (Unlike all, nothing runs concurrently.)
	var each_r: Array = await Promise.each(["load", "decode", "apply"],
		func(step, i):
			return Promise.delay(0.02).and_then_return("%d:%s" % [i, step])
	).await_status()
	print("each -> ", each_r[1])

	# fold reduces with an accumulator; the reducer may also return promises.
	var fold_r: Array = await Promise.fold([1, 2, 3, 4],
		func(acc, v, _i): return acc + v, 0).await_status()
	print("fold -> ", fold_r[1])


# ---------------------------------------------------------------------------
# 8. retry — flaky operations
# ---------------------------------------------------------------------------
func _demo_retry() -> void:
	print("\n--- 8. retry ---")

	var attempts := [0]
	var flaky := func():
		attempts[0] += 1
		if attempts[0] < 3:
			return Promise.reject("attempt %d failed" % attempts[0])
		return Promise.resolve("succeeded on attempt %d" % attempts[0])

	# retry_with_delay waits between attempts; plain retry doesn't.
	var r: Array = await Promise.retry_with_delay(flaky, 5, 0.02).await_status()
	print("retry -> ", r[1])


# ---------------------------------------------------------------------------
# 9. timeout — bounded waits
# ---------------------------------------------------------------------------
func _demo_timeout() -> void:
	print("\n--- 9. timeout ---")

	var slow_op := Promise.delay(10.0).and_then_return("you'll never see this")
	var r: Array = await slow_op.timeout(0.05).await_status()
	if PromiseError.is_kind(r[1], PromiseError.Kind.TIMED_OUT):
		print("timed out as expected: ", r[1].message)
	# Note: hitting the timeout CANCELS the source promise (slow_op) when
	# nothing else consumes it — its work is genuinely abandoned, not leaked.
	print("source status after timeout: ",
			Promise.Status.keys()[slow_op.get_status()])


# ---------------------------------------------------------------------------
# 10. from_signal — bridge Godot signals into promises
# ---------------------------------------------------------------------------
func _demo_from_signal() -> void:
	print("\n--- 10. from_signal ---")

	# Resolve on the next emission that passes the predicate. The signal must
	# carry at most ONE argument (pack multiple values into a Dictionary).
	var rare_drop := Promise.from_signal(loot_dropped,
			func(item): return item.rarity == "legendary")

	# Simulate gameplay emitting loot over time:
	get_tree().create_timer(0.02).timeout.connect(func():
		loot_dropped.emit({"name": "Rusty Sword", "rarity": "common"}))
	get_tree().create_timer(0.05).timeout.connect(func():
		loot_dropped.emit({"name": "Excalibur", "rarity": "legendary"}))

	# Tip: pair from_signal with timeout() so a signal that never fires can't
	# strand the promise forever.
	var r: Array = await rare_drop.timeout(1.0).await_status()
	print("legendary drop: ", r[1].name)


# ---------------------------------------------------------------------------
# 11. Cancellation — hooks and propagation
# ---------------------------------------------------------------------------
func _demo_cancellation() -> void:
	print("\n--- 11. Cancellation ---")

	# Register cleanup with on_cancel; it runs if the promise is cancelled.
	var download := Promise.new_promise(func(_resolve, _reject, on_cancel):
		print("starting fake download...")
		on_cancel.call(func(): print("on_cancel hook: aborting download"))
	)
	var ui_update := download.and_then(func(v): return v)

	# Cancellation propagates BOTH ways through chains:
	#   * cancelling a promise cancels everything chained from it, and
	#   * cancelling the LAST consumer of a promise cancels the promise too.
	ui_update.cancel()
	print("download is now: ",
			Promise.Status.keys()[download.get_status()]) # CANCELLED (upward)

	# With two consumers, cancelling one leaves the parent (and the other
	# consumer) alive — a promise dies only when nobody is left wanting it.
	var source := Promise.delay(0.05).and_then_return("shared result")
	var consumer_a := source.and_then(func(v): return "A got %s" % v)
	var consumer_b := source.and_then(func(v): return "B got %s" % v)
	consumer_b.cancel()
	var r: Array = await consumer_a.await_status()
	print("after cancelling B: ", r[1])


# ---------------------------------------------------------------------------
# 12. THE gotcha — awaiting does not count as consuming
# ---------------------------------------------------------------------------
func _demo_cancellation_gotcha() -> void:
	print("\n--- 12. The await gotcha ---")

	# Only and_then / catch / tap register as consumers. A bare `await` does
	# NOT — so a promise you pass to race()/timeout() can be cancelled out
	# from under your await:
	var save := Promise.delay(0.2).and_then_return("saved")
	Promise.race([save, Promise.delay(0.02)]) # the short delay wins...
	await get_tree().create_timer(0.05).timeout
	print("save without a consumer: ",
			Promise.Status.keys()[save.get_status()]) # CANCELLED

	# The fix: attach a real consumer (a passthrough is enough) before
	# handing the promise to a combinator:
	var safe_save := Promise.delay(0.1).and_then_return("saved")
	var keep_alive := safe_save.and_then(func(v): return v)
	Promise.race([safe_save, Promise.delay(0.02)])
	var r: Array = await keep_alive.await_status()
	print("save with a keep-alive consumer: ", r[1])