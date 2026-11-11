import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:mmx_core/mmx_core.dart';

import '../state/studio_state.dart';

/// Draft controls commit together, so selecting a texture never edits the scene.
class MaterialPanel extends StatefulWidget {
  final StudioState state;
  const MaterialPanel({super.key, required this.state});

  @override
  State<MaterialPanel> createState() => _MaterialPanelState();
}

class _MaterialPanelState extends State<MaterialPanel> {
  final _channels = List.generate(4, (_) => TextEditingController());
  int? _objectId;
  TriMesh? _mesh;
  String? _texturePath;
  bool _removeTexture = false;
  bool _clamp = false;
  bool _applying = false;
  bool _pickingTexture = false;
  int _uvAxis = -1;
  String? _error;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _objectId = widget.state.selected?.id;
    _mesh = widget.state.activeMesh;
    final material = _mesh?.materials.firstOrNull;
    final color = material?.baseColor ?? [1.0, 1.0, 1.0, 1.0];
    for (var i = 0; i < 4; i++) {
      _channels[i].text = color[i].toString();
    }
    _texturePath = null;
    _removeTexture = false;
    _clamp = material?.textureClamp ?? false;
    _uvAxis = -1;
    _error = null;
    _message = null;
  }

  @override
  void didUpdateWidget(covariant MaterialPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_objectId != widget.state.selected?.id ||
        (!_applying && !identical(_mesh, widget.state.activeMesh))) {
      _load();
    }
  }

  @override
  void dispose() {
    for (final channel in _channels) {
      channel.dispose();
    }
    super.dispose();
  }

  Future<void> _chooseTexture() async {
    final objectId = widget.state.selected?.id;
    if (widget.state.interactionLocked || objectId == null) return;
    setState(() => _pickingTexture = true);
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'PNG or JPEG texture',
            extensions: ['png', 'jpg', 'jpeg'],
          ),
        ],
      );
      if (!mounted || file == null) return;
      if (widget.state.selected?.id != objectId) {
        setState(() => _error = 'Selection changed; choose the texture again.');
        return;
      }
      setState(() {
        _texturePath = file.path;
        _removeTexture = false;
        // The user can review/change the projection before applying the draft.
        if (_mesh?.cornerUvs == null && _uvAxis < 0) _uvAxis = 1;
        _error = null;
        _message = 'Texture selected. Apply to update the object.';
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Texture selection failed: $e');
    } finally {
      if (mounted) setState(() => _pickingTexture = false);
    }
  }

  Future<void> _apply() async {
    final color = _channels.map((c) => double.tryParse(c.text)).toList();
    if (color.any((v) => v == null || !v.isFinite || v < 0 || v > 1)) {
      setState(
        () => _error = 'Each RGBA channel must be a finite number from 0 to 1.',
      );
      return;
    }
    await _run(
      () => widget.state.applySelectedMaterial(
        baseColor: color.cast<double>(),
        texturePath: _texturePath,
        removeTexture: _removeTexture,
        planarAxis: _uvAxis < 0 ? null : _uvAxis,
        textureClamp: _clamp,
      ),
    );
  }

  Future<void> _run(Future<bool> Function() action) async {
    if (widget.state.interactionLocked || _applying || _pickingTexture) return;
    setState(() {
      _applying = true;
      _error = null;
      _message = null;
    });
    bool succeeded;
    try {
      succeeded = await action();
    } catch (e) {
      if (mounted) {
        setState(() {
          _applying = false;
          _error = 'Material operation failed: $e';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _applying = false;
      if (succeeded) _load();
      // Failed transactions may replace the mesh with their rollback copy.
      // Keep this draft and error instead of resetting on the next notification.
      _mesh = widget.state.activeMesh;
      _objectId = widget.state.selected?.id;
      if (succeeded) {
        _message = widget.state.status;
      } else {
        _error = widget.state.status;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final mesh = state.activeMesh;
    final locked =
        state.interactionLocked || _applying || _pickingTexture || mesh == null;
    final existing = _removeTexture
        ? null
        : mesh?.materials.firstOrNull?.texture;
    final textureName = _texturePath == null
        ? existing?.name
        : File(_texturePath!).uri.pathSegments.last;
    final color = _channels.map((c) => double.tryParse(c.text)).toList();
    final validColor = color.every(
      (v) => v != null && v.isFinite && v >= 0 && v <= 1,
    );
    return FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          key: const ValueKey('material-panel'),
          tilePadding: EdgeInsets.zero,
          title: const Text(
            'Material and texture',
            style: TextStyle(fontSize: 13),
          ),
          subtitle: Text(
            '${mesh?.materials.length ?? 0} materials · ${mesh?.cornerUvs == null ? 'no UVs' : 'UVs available'}',
            style: const TextStyle(fontSize: 11),
          ),
          children: [
            const Text(
              'Apply assigns one material to every face of the selected object.',
              style: TextStyle(fontSize: 11),
            ),
            const SizedBox(height: 8),
            if (validColor)
              Semantics(
                label: 'Draft RGBA color ${color.join(', ')}',
                child: Container(
                  height: 20,
                  color: Color.from(
                    red: color[0]!,
                    green: color[1]!,
                    blue: color[2]!,
                    alpha: color[3]!,
                  ),
                ),
              ),
            const SizedBox(height: 10),
            for (var row = 0; row < 2; row++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    for (var col = 0; col < 2; col++) ...[
                      if (col > 0) const SizedBox(width: 10),
                      Expanded(
                        child: TextFormField(
                          key: ValueKey('material-rgba-${row * 2 + col}'),
                          controller: _channels[row * 2 + col],
                          enabled: !locked,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText:
                                '${['Red', 'Green', 'Blue', 'Alpha'][row * 2 + col]} (0–1)',
                            isDense: true,
                          ),
                          onChanged: (_) => setState(() => _error = null),
                          onFieldSubmitted: (_) => _apply(),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                textureName == null ? 'No texture' : 'Texture: $textureName',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: locked ? null : _chooseTexture,
                  child: const Text('Choose texture…'),
                ),
                TextButton(
                  onPressed: locked || textureName == null
                      ? null
                      : () => setState(() {
                          _texturePath = null;
                          _removeTexture = true;
                          _message = 'Texture removal staged. Apply to update the object.';
                        }),
                  child: const Text('Remove texture'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              key: ValueKey('material-uv-$_uvAxis'),
              isExpanded: true,
              initialValue: _uvAxis,
              decoration: const InputDecoration(
                labelText: 'UV mapping',
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: -1, child: Text('Keep existing UVs')),
                DropdownMenuItem(value: 0, child: Text('Planar X (YZ plane)')),
                DropdownMenuItem(value: 1, child: Text('Planar Y (XZ plane)')),
                DropdownMenuItem(value: 2, child: Text('Planar Z (XY plane)')),
              ],
              onChanged: locked
                  ? null
                  : (axis) => setState(() => _uvAxis = axis!),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text(
                'Clamp texture edges',
                style: TextStyle(fontSize: 12),
              ),
              value: _clamp,
              onChanged: locked
                  ? null
                  : (value) => setState(() => _clamp = value!),
            ),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  key: const ValueKey('apply-material'),
                  onPressed: locked ? null : _apply,
                  child: const Text('Apply material'),
                ),
                OutlinedButton(
                  onPressed: locked || !mesh.hasSurfaceAttributes
                      ? null
                      : () => _run(state.removeSelectedSurfaceAttributes),
                  child: const Text('Remove materials and UVs'),
                ),
              ],
            ),
            if (_error != null || _message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _error ?? _message!,
                    style: TextStyle(
                      fontSize: 12,
                      color: _error == null
                          ? Colors.white70
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            const Text(
              'PNG/JPEG: up to 16 MiB and 4096×4096. Preview uses alpha cutout at 0.5; .mmx saves the original alpha and texture.',
              style: TextStyle(fontSize: 11, color: Colors.white70),
            ),
            if (mesh?.vertexColors != null)
              const Text(
                'Existing vertex colors also tint the material.',
                style: TextStyle(fontSize: 11),
              ),
            const SizedBox(height: 14),
          ],
        ),
      ),
    );
  }
}
