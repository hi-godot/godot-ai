# Raw shader authoring

`material_manage` exposes raw `.gdshader` / `.gdshaderinc` authoring alongside
the material ops. Every write compiles the staged bytes through Godot's own
shader compiler **before** the destination file is touched, so invalid code
never reaches disk and a failed validation preserves an existing file. All
shader file writes report `undoable: false`; delete the file to revert.

## Ops

| Op | Purpose |
|----|---------|
| `shader_create(resource_path, code, overwrite=false, shader_type="spatial")` | Validate + atomically write a `.gdshader` or `.gdshaderinc`. |
| `shader_get(path)` | Full source + parsed metadata. Resource form: `godot://shader/{path}`. |
| `shader_validate(code, kind="shader", shader_type="spatial")` | Compile-check source without writing anything. |
| `shader_list(root="res://")` | List `.gdshader` / `.gdshaderinc` files. |
| `shader_patch(path, old_text, new_text, replace_all=false)` | Exact-match edit, revalidated before replacement. |

`material_manage(op="create", type="shader", code=...)` embeds an inline
`Shader` in a `ShaderMaterial` in one call (mutually exclusive with
`shader_path`); the code is compiled before the `.tres` is saved.

## Create workflow

```json
{
  "op": "shader_create",
  "params": {
    "resource_path": "res://shaders/pulse.gdshader",
    "code": "shader_type spatial;\nuniform float pulse : hint_range(0.0, 1.0) = 0.5;\n\nvoid fragment() {\n\tALBEDO = vec3(pulse);\n}\n"
  }
}
```

On success the response carries `kind` (`"shader"` / `"include"`),
`shader_type`, the parsed `uniforms` (name, type, hint, hint_string, default
when the engine reports one), `line_count`, and — for a fresh file — a
`cleanup.rm` hint listing the file plus its `.uid` sidecar. `overwrite`
defaults to `false` and refuses to replace an existing file.

On a parse failure the op returns `INVALID_PARAMS` with
`error.data.diagnostics` / `errors` / `warnings`, each entry carrying
`level`, `text`, `path`, `line`, and `function`. The destination is left
untouched.

## Validation model

- Validity is detected through the engine's own parser using a sentinel
  uniform: a scratch copy of the code (or of the `#include` wrapper for a
  `.gdshaderinc`) gets a generated `uniform float _mcp_validate_<token>;`
  appended, and `Shader.get_shader_uniform_list()` is populated only when the
  whole translation unit parses. A missing sentinel means the code failed to
  compile.
- `.gdshaderinc` cannot compile on its own, so it is wrapped in a minimal
  `shader_type <shader_type>; #include "<scratch>"` shader in the same
  directory. `shader_type` (default `spatial`) selects the wrapper context for
  includes that rely on stage-specific builtins.
- `shader_validate` compiles a scratch copy under `user://` and removes it, so
  an inspection call never registers anything with the project filesystem.
- Godot exposes no structured compile-error API to GDScript: the compiler's
  line-tagged output only reaches the editor Output panel. A failed validation
  therefore returns one synthesized `error` diagnostic pointing at the Output
  panel; the destination is still never written.
- Validation is the engine's parse/type pass for the declared shader type;
  variant compilation that only happens when a material is rendered (for
  example, a stage-specific builtin used in the wrong function) is outside its
  scope.

## Patch workflow

`shader_patch` mirrors `script_patch`: `old_text` must match exactly once
unless `replace_all=true`, and the result is revalidated before the file is
replaced. A failed validation leaves the original bytes in place.

## Editing materials with a raw shader

1. `material_manage(op="shader_create", params={...})` — write the shader.
2. `material_manage(op="create", params={"path": "res://mat/pulse.tres", "type": "shader", "shader_path": "res://shaders/pulse.gdshader"})`.
3. `material_manage(op="assign", params={"node_path": "/Main/Sphere", "resource_path": "res://mat/pulse.tres"})`.
4. `material_manage(op="set_shader_param", params={"path": "res://mat/pulse.tres", "param": "pulse", "value": 0.8})`.

Assignment and uniform writes are undoable; the shader file itself is not.

Pin `session_id` at the tool's top level when multiple editors are connected.
