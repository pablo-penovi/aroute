# aroute

A two-column patchbay for wiring PipeWire audio and ALSA/PipeWire MIDI between devices on one machine.

## Language

### The graph

**Device**:
A physical or virtual thing that produces or consumes signal: a PipeWire node or an ALSA sequencer client (e.g. the MiniFuse, Renoise, a BLE MIDI keyboard).
_Avoid_: Node, client (as a user-facing term)

**Endpoint**:
One pickable row in a column: one direction and one kind (audio or MIDI) of a Device, sometimes narrowed to a single channel group of it (e.g. "MiniFuse 1 Main Output L/R"). An Endpoint groups one or more Ports.
_Avoid_: Device (when meaning a row), input, output

**Port**:
A single channel-level socket on a Device, as PipeWire or ALSA exposes it (e.g. the left channel of a stereo output). Never picked directly by the user.
_Avoid_: Channel, pin

**Source**:
An Endpoint that emits signal; shown in the FROM column. A hardware input such as a microphone jack is a Source.
_Avoid_: Input, output, from-endpoint

**Destination**:
An Endpoint that receives signal; shown in the TO column. A hardware output such as speakers is a Destination.
_Avoid_: Output, input, sink, to-endpoint

**Kind**:
Whether an Endpoint carries audio or MIDI. Only Endpoints of the same Kind can be connected.

### Wiring

**Link**:
One Port-to-Port wire in the graph.
_Avoid_: Patch, cable

**Connection**:
All the Links between one Source and one Destination, treated as one unit: what the user makes, sees and undoes.
_Avoid_: Route, link (when meaning the whole unit)

### Saved state

**Profile**:
A named, saved set of Connections that can be loaded to make the whole graph match it.
_Avoid_: Preset, scene, snapshot
