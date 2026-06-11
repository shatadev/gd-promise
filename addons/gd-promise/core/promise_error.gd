class_name PromiseError
extends RefCounted

enum Kind { 
	EXECUTION_ERROR, 
	ALREADY_CANCELLED, 
	NOT_RESOLVED_IN_TIME, 
	TIMED_OUT 
}

var message : String
var kind    : Kind
var context : String
var parent  : PromiseError   # linked list of causes

func _init(p_msg: String, p_kind: Kind = Kind.EXECUTION_ERROR,
		p_ctx: String = "", p_parent: PromiseError = null) -> void:
	message = p_msg
	kind    = p_kind
	context = p_ctx
	parent  = p_parent

## Create a child error that wraps this one as its cause.
func extend(p_msg: String, p_ctx: String = "") -> PromiseError:
	return PromiseError.new(p_msg, kind, p_ctx, self)

func _to_string() -> String:
	var parts := ["-- Promise.Error(%s) --" % Kind.keys()[kind], message]
	if context != "":
		parts.append(context)
	var cur := parent
	while cur != null:
		parts.append(cur.message)
		cur = cur.parent
	return "\n".join(parts)

static func is_kind(value: Variant, k: Kind) -> bool:
	return value is PromiseError and value.kind == k
	