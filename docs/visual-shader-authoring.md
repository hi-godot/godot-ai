# VisualShader graph authoring

`material_manage(op="visual_shader_create_graph")` validates and saves a new
VisualShader `.tres`. It does not assign a material or change the scene. File
creation/replacement is not undoable; `overwrite` defaults to `false`.

```json
{
  "op": "visual_shader_create_graph",
  "params": {
    "resource_path": "res://orange.tres",
    "stages": [{
      "stage": "fragment",
      "nodes": [{
        "id": "color", "type": "VisualShaderNodeColorConstant",
        "params": {"constant": {"r": 1, "g": 0.25, "b": 0.1, "a": 1}}
      }],
      "connections": [{"from_node": "color", "from_port": 0,
                       "to_node": "output", "to_port": 0}]
    }]
  }
}
```

`shader_type` defaults to `spatial`. Spatial and canvas shaders accept
`vertex`, `fragment`, and `light`; particles accept `start`, `process`,
`collide`, `start_custom`, and `process_custom`; sky and fog accept their
respective `sky` and `fog` stages. Stages cannot repeat. Nodes and edges are
local to their containing stage; direct cross-stage connections are rejected.
Varying declarations and editing existing graphs are outside this operation.

Node IDs are integers from 2 through 2147483647 or nonempty strings other than
`output`. Each stage reserves all explicit integer IDs first, then assigns
strings the lowest free integers in request order. `id_map` returns an array
of `{id, node_id}` entries per stage, preserving integer/string identity and
request order. Connections target the built-in output through `"output"` or 0.
Positions are optional `{x, y}` objects. Request limits are 256 nodes and 1024
connections across all stages; port indices are integers from 0 through 64.

Types must be instantiable engine VisualShaderNode subclasses. Output nodes,
script-backed custom nodes, and expression nodes cannot be created. Supported
properties, when exposed and writable on that class, are `constant`, `texture`,
`operator`, `function`, `op_type`, `input_name`, `parameter_name`,
`default_value_enabled`, `default_value`, `qualifier`, `source`, `texture_type`,
`texture_filter`, `texture_repeat`, `hint`, and `hint_range_min/max/step`.
Colors use `{r,g,b,a?}`, vectors `{x,y,z?,w?}`, and numeric values must be finite.
Enums accept engine names or valid integers. Texture paths must be project
resources of the node's required texture type. Unknown properties are errors.

Legacy aliases retained from the proposal: ScalarOp/ScalarFunc map to
FloatOp/FloatFunc; VectorConstant/VectorParameter to Vec3Constant/Vec3Parameter;
Time to Input(time), Sin/Cos to FloatFunc(sin/cos), Length to VectorLen. These
names have the `VisualShaderNode` prefix. Enum aliases include sub/mul/div/mod/pow.

The destination must be a `.tres` beneath `res://` with an existing parent
directory. All stages are built and validated in memory before a temporary
file is saved beside the destination and atomically renamed into place.
Validation, save, or replacement failure preserves the existing file.

To use the shader, make two separate `material_manage` calls:

1. `create` with `path="res://orange_material.tres"`, `type="shader"`, and
   `shader_path="res://orange.tres"`.
2. `assign` with `node_path="/Main/Sphere"`,
   `resource_path="res://orange_material.tres"`, and `slot="override"`.

Assignment is undoable; undoing it leaves both resource files intact. Pin
`session_id` at the tool's top level when multiple editors are connected.
