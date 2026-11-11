import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../state/studio_state.dart';

/// Keyboard and assistive-technology alternative to the viewport handles.
class ManipulatorControls extends StatefulWidget {
  final StudioState state;
  const ManipulatorControls({super.key, required this.state});

  @override
  State<ManipulatorControls> createState() => _ManipulatorControlsState();
}

class _ManipulatorControlsState extends State<ManipulatorControls> {
  late ManipulatorMode _mode = widget.state.manipulatorMode;
  late final TextEditingController _amount = TextEditingController(
    text: _mode == ManipulatorMode.scale ? '1' : '0',
  );
  int _axis = 0;
  String? _error;
  String? _snapError;

  @override
  void didUpdateWidget(covariant ManipulatorControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_mode != widget.state.manipulatorMode) {
      _mode = widget.state.manipulatorMode;
      _amount.text = _mode == ManipulatorMode.scale ? '1' : '0';
      _error = null;
      _snapError = null;
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final state = widget.state;
    if (state.interactionLocked || _snapError != null) return;
    var value = double.tryParse(_amount.text);
    if (value == null ||
        !value.isFinite ||
        (_mode == ManipulatorMode.scale && (value < .01 || value > 100))) {
      setState(
        () => _error = _mode == ManipulatorMode.scale
            ? 'Enter a factor from 0.01 to 100'
            : 'Enter a finite number',
      );
      return;
    }
    setState(() => _error = null);
    if (_mode == ManipulatorMode.rotate) value *= math.pi / 180;
    await state.applyManipulatorAmount(_axis, value);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final locked = state.interactionLocked || state.selected == null;
    final active = _mode != ManipulatorMode.none;
    final snap = state.manipulatorSnap;
    final snapValue = switch (_mode) {
      ManipulatorMode.rotate => snap.rotationDegrees,
      ManipulatorMode.scale => snap.scale * 100,
      _ => snap.translation,
    };
    final snapLabel = switch (_mode) {
      ManipulatorMode.rotate => 'Rotation snap (degrees)',
      ManipulatorMode.scale => 'Scale snap (%)',
      _ => 'Move snap (mm)',
    };
    final amountLabel = switch (_mode) {
      ManipulatorMode.rotate => 'Angle (degrees)',
      ManipulatorMode.scale => 'Scale factor',
      _ => 'Distance (mm)',
    };
    return FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'TRANSFORM',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<ManipulatorMode>(
              key: ValueKey('numeric-mode-${state.manipulatorMode.name}'),
              initialValue: state.manipulatorMode,
              decoration: const InputDecoration(
                labelText: 'Operation',
                isDense: true,
              ),
              items: [
                for (final mode in ManipulatorMode.values)
                  DropdownMenuItem(
                    value: mode,
                    child: Text(switch (mode) {
                      ManipulatorMode.none => 'Off',
                      ManipulatorMode.translate => 'Move',
                      ManipulatorMode.rotate => 'Rotate',
                      ManipulatorMode.scale => 'Scale',
                      ManipulatorMode.pivot => 'Move pivot',
                    }),
                  ),
              ],
              onChanged: locked
                  ? null
                  : (mode) => state.setManipulatorMode(mode!),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<ManipulatorSpace>(
              key: ValueKey('manipulator-space-${state.manipulatorSpace.name}'),
              initialValue: state.manipulatorSpace,
              decoration: const InputDecoration(
                labelText: 'Coordinate space',
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(
                  value: ManipulatorSpace.world,
                  child: Text('World axes'),
                ),
                DropdownMenuItem(
                  value: ManipulatorSpace.local,
                  child: Text('Local axes'),
                ),
              ],
              onChanged: locked
                  ? null
                  : (space) => state.setManipulatorSpace(space!),
            ),
            if (_mode == ManipulatorMode.scale) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<ManipulatorScaleMode>(
                key: ValueKey('scale-mode-${state.manipulatorScaleMode.name}'),
                initialValue: state.manipulatorScaleMode,
                decoration: const InputDecoration(
                  labelText: 'Scaling',
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(
                    value: ManipulatorScaleMode.axis,
                    child: Text('Selected axis'),
                  ),
                  DropdownMenuItem(
                    value: ManipulatorScaleMode.uniform,
                    child: Text('Uniform'),
                  ),
                ],
                onChanged: locked
                    ? null
                    : (mode) => state.setManipulatorScaleMode(mode!),
              ),
            ],
            if (active) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Snap', style: TextStyle(fontSize: 13)),
                value: snap.enabled,
                onChanged: locked
                    ? null
                    : (enabled) {
                        setState(() => _snapError = null);
                        state.setManipulatorSnap(
                          ManipulatorSnap(
                            enabled: enabled,
                            translation: snap.translation,
                            rotationDegrees: snap.rotationDegrees,
                            scale: snap.scale,
                          ),
                        );
                      },
              ),
              if (snap.enabled)
                TextFormField(
                  key: ValueKey('snap-increment-${_mode.name}'),
                  initialValue: '$snapValue',
                  enabled: !locked,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: snapLabel,
                    errorText: _snapError,
                    isDense: true,
                  ),
                  onChanged: (text) {
                    final value = double.tryParse(text);
                    final valid = value != null && value.isFinite && value > 0;
                    setState(
                      () => _snapError = valid
                          ? null
                          : 'Enter a positive finite increment',
                    );
                    if (!valid) return;
                    state.setManipulatorSnap(
                      ManipulatorSnap(
                        enabled: true,
                        translation:
                            _mode == ManipulatorMode.rotate ||
                                _mode == ManipulatorMode.scale
                            ? snap.translation
                            : value,
                        rotationDegrees: _mode == ManipulatorMode.rotate
                            ? value
                            : snap.rotationDegrees,
                        scale: _mode == ManipulatorMode.scale
                            ? value / 100
                            : snap.scale,
                      ),
                    );
                  },
                ),
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                initialValue: _axis,
                decoration: const InputDecoration(
                  labelText: 'Axis',
                  isDense: true,
                ),
                items: [
                  for (var axis = 0; axis < 3; axis++)
                    DropdownMenuItem(
                      value: axis,
                      child: Text(['X', 'Y', 'Z'][axis]),
                    ),
                ],
                onChanged:
                    locked ||
                        (_mode == ManipulatorMode.scale &&
                            state.manipulatorScaleMode ==
                                ManipulatorScaleMode.uniform)
                    ? null
                    : (axis) => setState(() => _axis = axis!),
              ),
              const SizedBox(height: 10),
              TextFormField(
                key: const ValueKey('manipulator-amount'),
                controller: _amount,
                enabled: !locked,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: amountLabel,
                  errorText: _error,
                  isDense: true,
                ),
                onFieldSubmitted: (_) => _apply(),
              ),
              const SizedBox(height: 10),
              FilledButton(
                key: const ValueKey('apply-manipulator'),
                onPressed: locked || _snapError != null ? null : _apply,
                child: const Text('Apply transform'),
              ),
              const SizedBox(height: 8),
              const Text(
                'Amounts are relative to the current position and pivot. Drag an axis in the view; Escape cancels the drag.',
                style: TextStyle(fontSize: 11, color: Colors.white70),
              ),
            ],
            const SizedBox(height: 14),
          ],
        ),
      ),
    );
  }
}
