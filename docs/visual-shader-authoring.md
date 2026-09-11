# VisualShader graph authoring

`material_manage` exposes four VisualShader ops: `visual_shader_create_graph`
(validate and save a new `.tres`), `visual_shader_get` (inspect an existing
graph; resource form `godot://visual_shader/{path}`),
`visual_shader_node_catalog` (discover valid node classes and their supported
properties), and `visual_shader_edit` (apply a validated operation list to an
existing graph). None of them assign a material or change the scene. File
creation/replacement/editing is not undoable; `overwrite` defaults to `false`.

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
Varyings are declared through the optional top-level `varyings` array
(spatial/canvas_item only):

```json
{
  "varyings": [
    {"name": "glow", "mode": "frag_to_light", "type": "vector3"}
  ]
}
```

`mode` is `vertex_to_frag_light` or `frag_to_light`; `type` is one of `float`,
`int`, `uint`, `vector2`, `vector3`, `vector4`, `boolean`, `transform`.
Engine enum names (`VARYING_MODE_...`, `VARYING_TYPE_...`) are also accepted.

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

## Inspecting a graph

`visual_shader_get(path)` returns `shader_type`, the non-empty stages with
their nodes (`id`, `type`, `position`, supported `params`), `connections`, and
`varyings`. It is the read half of an edit loop: read, patch, re-read.

```json
{"op": "visual_shader_get", "params": {"path": "res://orange.tres"}}
```

The engine exposes varying names through dynamic `varyings/<name>` properties
but has no mode/type getters; mode/type are recovered from the serialized
resource values, so a varying reports `name` only if the value cannot be read.

## Discovering nodes

`visual_shader_node_catalog(filter="", offset=0, limit=100)` lists every
instantiable VisualShaderNode class (excluding output/custom/expression nodes)
with the properties this tool accepts for it, plus the legacy `aliases` map.
Use it before authoring a graph instead of guessing class names:

```json
{"op": "visual_shader_node_catalog", "params": {"filter": "Float", "limit": 20}}
```

## Editing an existing graph

`visual_shader_edit(resource_path, operations)` applies an ordered operation
list to an existing `.tres` and saves atomically. The whole result is validated
in memory first: a failure at any operation returns an error and leaves the
file untouched. Supported operations:

| Op | Fields |
|----|--------|
| `add_node` | `stage`, `type`, optional `id`, `position`, `params` |
| `remove_node` | `stage`, `id` |
| `replace_node` | `stage`, `id`, `type`, optional `params` |
| `set_node_params` | `stage`, `id`, `params` |
| `set_node_position` | `stage`, `id`, `position` |
| `connect` / `disconnect` | `stage`, `from_node`, `from_port`, `to_node`, `to_port` |
| `add_varying` | `name`, `mode`, `type` |
| `remove_varying` | `name` |

`add_node` without an `id` gets the next free integer. A string `id` is
allocated an integer and returned in `added` as `{id, node_id, stage}`, so
later operations in the same call can reference it by that string. Numeric IDs
address existing nodes directly. Limits are 512 operations per call and 256
nodes / 1024 connections in the result.

```json
{
  "op": "visual_shader_edit",
  "params": {
    "resource_path": "res://orange.tres",
    "operations": [
      {"op": "add_node", "stage": "fragment", "id": "glow",
       "type": "VisualShaderNodeFloatConstant", "params": {"constant": 0.8}},
      {"op": "connect", "stage": "fragment", "from_node": "glow",
       "from_port": 0, "to_node": "output", "to_port": 3}
    ]
  }
}
```

To use the shader, make two separate `material_manage` calls:

1. `create` with `path="res://orange_material.tres"`, `type="shader"`, and
   `shader_path="res://orange.tres"`.
2. `assign` with `node_path="/Main/Sphere"`,
   `resource_path="res://orange_material.tres"`, and `slot="override"`.

Assignment is undoable; undoing it leaves both resource files intact. Pin
`session_id` at the tool's top level when multiple editors are connected.
