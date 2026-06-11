# example_interactive.gd
# An interactive playground for gd-promise. Open example_interactive.tscn and
# run it (or attach this script to any full-rect Control node).
#
# Five panels let you drive promises by hand:
#   1. Manual promise — create one, then resolve / reject / cancel it with a
#      value YOU type, and watch the chain + finally + on_cancel hook react.
#   2. Delay vs timeout — race a delay against a timeout you choose, and see
#      the source get auto-cancelled (or survive, with the keep-alive toggle).
#   3. Race / All — two delays with your durations; losers get auto-cancelled.
#   4. Retry — a flaky operation that fails N times before succeeding.
#   5. from_signal — wait for a signal emission matching the text you enter.
#
# NOTE: every handler in this file is a plain synchronous function — there is
# not a single `await` in this script. All promise consumption is
# callback-style (and_then / catch / finally_cb), which is the natural fit
# for UI code.

extends Control

signal demo_emitted(value)

const COL_OK := "light_green"
const COL_ERR := "salmon"
const COL_DIM := "gray"
const COL_INFO := "white"

var _manual := {} # { "promise": Promise, "resolve": Callable, "reject": Callable }

# Built in _ready:
var _controls: VBoxContainer
var _log_view: RichTextLabel
var _value_edit: LineEdit
var _manual_status: Label
var _delay_spin: SpinBox
var _timeout_spin: SpinBox
var _keepalive_check: CheckBox
var _a_spin: SpinBox
var _b_spin: SpinBox
var _b_rejects: CheckBox
var _fail_spin: SpinBox
var _retry_spin: SpinBox
var _target_edit: LineEdit
var _emit_edit: LineEdit


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------
func _ready() -> void:
	var split := HSplitContainer.new()
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(split)

	# Left: scrollable control panels -------------------------------------
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(440, 0)
	split.add_child(scroll)
	_controls = VBoxContainer.new()
	_controls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_controls.add_theme_constant_override("separation", 10)
	scroll.add_child(_controls)

	_build_manual_panel()
	_build_timeout_panel()
	_build_race_panel()
	_build_retry_panel()
	_build_signal_panel()

	# Right: log ------------------------------------------------------------
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	var header := HBoxContainer.new()
	right.add_child(header)
	var title := Label.new()
	title.text = "Log"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_button(header, "Clear", func(): _log_view.clear())
	_log_view = RichTextLabel.new()
	_log_view.bbcode_enabled = true
	_log_view.scroll_following = true
	_log_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(_log_view)

	_log("ready — every handler here is callback-style, zero awaits", COL_DIM)


func _build_manual_panel() -> void:
	var box := _section("1. Manual promise")
	_note(box, "Create a pending promise, then settle it yourself with the\nvalue below. Settling twice is an idempotent no-op.")
	var row := _row(box)
	_value_edit = _line_edit(row, "value to settle with", "hello")
	var row2 := _row(box)
	_button(row2, "New promise", _on_new_manual)
	_button(row2, "Resolve", _on_manual_resolve)
	_button(row2, "Reject", _on_manual_reject)
	_button(row2, "Cancel", _on_manual_cancel)
	_manual_status = Label.new()
	_manual_status.text = "status: (none yet)"
	box.add_child(_manual_status)


func _build_timeout_panel() -> void:
	var box := _section("2. Delay vs timeout")
	_note(box, "If timeout < delay it fires first, rejects with TIMED_OUT and\nCANCELS the source — unless a keep-alive consumer protects it.")
	var row := _row(box)
	_delay_spin = _spin(row, "delay", 0.1, 10.0, 0.1, 2.0)
	_timeout_spin = _spin(row, "timeout", 0.1, 10.0, 0.1, 1.0)
	_keepalive_check = CheckBox.new()
	_keepalive_check.text = "attach keep-alive consumer to source"
	box.add_child(_keepalive_check)
	_button(_row(box), "Run", _on_run_timeout)


func _build_race_panel() -> void:
	var box := _section("3. Race / All")
	_note(box, "Two delayed promises with your durations. After race(), the\nloser is auto-cancelled (it has no other consumers).")
	var row := _row(box)
	_a_spin = _spin(row, "A", 0.1, 10.0, 0.1, 0.5)
	_b_spin = _spin(row, "B", 0.1, 10.0, 0.1, 1.5)
	_b_rejects = CheckBox.new()
	_b_rejects.text = "B rejects instead of resolving"
	box.add_child(_b_rejects)
	var row2 := _row(box)
	_button(row2, "Race", _on_race)
	_button(row2, "All", _on_all)


func _build_retry_panel() -> void:
	var box := _section("4. Retry")
	_note(box, "A flaky operation that fails the first N attempts.\nretry_with_delay waits 0.3s between attempts.")
	var row := _row(box)
	_fail_spin = _spin(row, "failures", 0, 10, 1, 2)
	_retry_spin = _spin(row, "max retries", 0, 10, 1, 5)
	_button(_row(box), "Run", _on_retry)


func _build_signal_panel() -> void:
	var box := _section("5. from_signal")
	_note(box, "Wait for the next demo_emitted whose value matches the target\n(leave target empty to accept anything). 10s timeout cancels the\nwait and disconnects via the on_cancel hook.")
	var row := _row(box)
	_target_edit = _line_edit(row, "target value (optional)", "magic")
	_button(row, "Wait for signal", _on_wait_for_signal)
	var row2 := _row(box)
	_emit_edit = _line_edit(row2, "value to emit", "magic")
	_button(row2, "Emit", _on_emit)


# ---------------------------------------------------------------------------
# 1. Manual promise
# ---------------------------------------------------------------------------
func _on_new_manual() -> void:
	if _manual.has("promise") and (_manual.promise as Promise).get_status() == Promise.Status.PENDING:
		_log("cancelling the previous promise first", COL_DIM)
		(_manual.promise as Promise).cancel()

	var d := {}
	d["promise"] = Promise.new_promise(func(resolve, reject, on_cancel):
		d["resolve"] = resolve
		d["reject"] = reject
		on_cancel.call(func(): _log("  on_cancel hook ran", COL_DIM))
	)
	_manual = d

	var p := d.promise as Promise
	p.and_then(func(v): _log("  and_then got: %s" % str(v), COL_OK)) \
		.catch(func(r): _log("  catch got: %s" % str(r), COL_ERR))
	# finally passes the outcome (incl. rejections) through, so catch its
	# child to keep the log free of unhandled-rejection warnings:
	var f := p.finally_cb(func(s):
		_manual_status.text = "status: %s" % Promise.Status.keys()[s]
		_log("  finally ran with status %s" % Promise.Status.keys()[s], COL_DIM)
	)
	f.catch(func(_r): pass )

	_manual_status.text = "status: PENDING"
	_log("new promise created", COL_INFO)


func _on_manual_resolve() -> void:
	if not _manual.has("resolve"):
		_log("create a promise first", COL_ERR)
		return
	if (_manual.promise as Promise).get_status() != Promise.Status.PENDING:
		_log("already settled — settle calls are idempotent no-ops", COL_DIM)
	_manual.resolve.call(_value_edit.text)


func _on_manual_reject() -> void:
	if not _manual.has("reject"):
		_log("create a promise first", COL_ERR)
		return
	if (_manual.promise as Promise).get_status() != Promise.Status.PENDING:
		_log("already settled — settle calls are idempotent no-ops", COL_DIM)
	_manual.reject.call(_value_edit.text)


func _on_manual_cancel() -> void:
	if not _manual.has("promise"):
		_log("create a promise first", COL_ERR)
		return
	(_manual.promise as Promise).cancel()


# ---------------------------------------------------------------------------
# 2. Delay vs timeout
# ---------------------------------------------------------------------------
func _on_run_timeout() -> void:
	var d: float = _delay_spin.value
	var t: float = _timeout_spin.value
	_log("delay(%.1fs).timeout(%.1fs) started" % [d, t], COL_INFO)

	var source := Promise.delay(d).and_then_return("delay(%.1fs) finished" % d)
	if _keepalive_check.button_pressed:
		source.and_then(func(v): _log("  keep-alive consumer saw: %s" % str(v), COL_DIM))

	source.timeout(t) \
	.and_then(func(v): _log("  resolved in time: %s" % str(v), COL_OK)) \
	.catch(func(err):
		_log("  rejected: %s" % _describe(err), COL_ERR)
		_log("  source status now: %s" % Promise.Status.keys()[source.get_status()], COL_DIM)
	)


# ---------------------------------------------------------------------------
# 3. Race / All
# ---------------------------------------------------------------------------
func _make_racers() -> Array:
	var a := Promise.delay(_a_spin.value).and_then_return("A (%.1fs)" % _a_spin.value)
	var b: Promise
	if _b_rejects.button_pressed:
		b = Promise.delay(_b_spin.value).and_then(func(_v):
			return Promise.reject("B failed after %.1fs" % _b_spin.value))
	else:
		b = Promise.delay(_b_spin.value).and_then_return("B (%.1fs)" % _b_spin.value)
	return [a, b]


func _log_racer_statuses(a: Promise, b: Promise) -> void:
	_log("  A is now %s, B is now %s" % [
		Promise.Status.keys()[a.get_status()],
		Promise.Status.keys()[b.get_status()]], COL_DIM)


func _on_race() -> void:
	var pair := _make_racers()
	var a: Promise = pair[0]
	var b: Promise = pair[1]
	_log("race: A=%.1fs vs B=%.1fs%s" % [_a_spin.value, _b_spin.value,
			" (B will reject)" if _b_rejects.button_pressed else ""], COL_INFO)
	Promise.race([a, b]) \
		.and_then(func(winner):
			_log("  winner: %s" % str(winner), COL_OK)
			_log_racer_statuses(a, b)) \
		.catch(func(err):
			_log("  race rejected: %s" % _describe(err), COL_ERR)
			_log_racer_statuses(a, b))


func _on_all() -> void:
	var pair := _make_racers()
	var a: Promise = pair[0]
	var b: Promise = pair[1]
	_log("all: A=%.1fs + B=%.1fs%s" % [_a_spin.value, _b_spin.value,
			" (B will reject)" if _b_rejects.button_pressed else ""], COL_INFO)
	Promise.all([a, b]) \
		.and_then(func(values):
			_log("  all resolved: %s" % str(values), COL_OK)) \
		.catch(func(err):
			_log("  all rejected: %s" % _describe(err), COL_ERR)
			_log_racer_statuses(a, b))


# ---------------------------------------------------------------------------
# 4. Retry
# ---------------------------------------------------------------------------
func _on_retry() -> void:
	var fail_times := int(_fail_spin.value)
	var max_retries := int(_retry_spin.value)
	var attempts := [0]
	_log("retry: fails %d time(s), up to %d retries" % [fail_times, max_retries], COL_INFO)

	var flaky := func():
		attempts[0] += 1
		if attempts[0] <= fail_times:
			_log("  attempt %d failed" % attempts[0], COL_DIM)
			return Promise.reject("attempt %d failed" % attempts[0])
		_log("  attempt %d succeeded" % attempts[0], COL_DIM)
		return Promise.resolve("ok after %d attempt(s)" % attempts[0])

	Promise.retry_with_delay(flaky, max_retries, 0.3) \
		.and_then(func(v): _log("  retry resolved: %s" % str(v), COL_OK)) \
		.catch(func(err): _log("  retry exhausted: %s" % _describe(err), COL_ERR))


# ---------------------------------------------------------------------------
# 5. from_signal
# ---------------------------------------------------------------------------
func _on_wait_for_signal() -> void:
	var target := _target_edit.text
	var pred := Callable()
	if target != "":
		pred = func(v): return str(v) == target
	_log("waiting for demo_emitted%s, 10s timeout" %
			(" == \"%s\"" % target if target != "" else " (any value)"), COL_INFO)
	Promise.from_signal(demo_emitted, pred).timeout(10.0) \
		.and_then(func(v): _log("  signal matched: %s" % str(v), COL_OK)) \
		.catch(func(err): _log("  gave up waiting: %s" % _describe(err), COL_ERR))


func _on_emit() -> void:
	_log("emitting demo_emitted(\"%s\")" % _emit_edit.text, COL_DIM)
	demo_emitted.emit(_emit_edit.text)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
func _log(msg: String, color: String = COL_INFO) -> void:
	var safe := msg.replace("[", "[lb]")
	var t := Time.get_ticks_msec() / 1000.0
	_log_view.append_text("[color=dim_gray]%7.2f[/color]  [color=%s]%s[/color]\n" % [t, color, safe])


func _describe(reason: Variant) -> String:
	if reason is PromiseError:
		return "%s [%s]" % [reason.message, PromiseError.Kind.keys()[reason.kind]]
	return str(reason)


func _section(title: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	_controls.add_child(box)
	var lbl := Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 16)
	box.add_child(lbl)
	box.add_child(HSeparator.new())
	return box


func _note(parent: Control, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	lbl.add_theme_font_size_override("font_size", 12)
	parent.add_child(lbl)


func _row(parent: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	return row


func _button(parent: Control, text: String, on_pressed: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.pressed.connect(on_pressed)
	parent.add_child(btn)
	return btn


func _spin(parent: Control, label: String, minv: float, maxv: float,
		step: float, value: float) -> SpinBox:
	var lbl := Label.new()
	lbl.text = label
	parent.add_child(lbl)
	var spin := SpinBox.new()
	spin.min_value = minv
	spin.max_value = maxv
	spin.step = step
	spin.value = value
	spin.suffix = "s" if step < 1.0 else ""
	parent.add_child(spin)
	return spin


func _line_edit(parent: Control, placeholder: String, value: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.text = value
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(140, 0)
	parent.add_child(edit)
	return edit