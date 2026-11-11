import 'package:flutter/material.dart';

import '../state/studio_state.dart';

/// A software escape path and truthful adapter information are always visible.
class RendererControls extends StatelessWidget {
  final StudioState state;
  const RendererControls({super.key, required this.state});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      DropdownButton<RenderBackendPreference>(
        value: state.renderBackendPreference,
        isExpanded: true,
        items: const [
          DropdownMenuItem(
            value: RenderBackendPreference.auto,
            child: Text('Renderer: automatic'),
          ),
          DropdownMenuItem(
            value: RenderBackendPreference.gpu,
            child: Text('Renderer: prefer GPU'),
          ),
          DropdownMenuItem(
            value: RenderBackendPreference.cpu,
            child: Text('Renderer: CPU'),
          ),
        ],
        onChanged: state.interactionLocked
            ? null
            : (value) {
                if (value != null) state.setRenderBackend(value);
              },
      ),
      Tooltip(
        message: state.renderDiagnostic,
        child: Text(
          state.renderBackend,
          style: const TextStyle(fontSize: 11, color: Colors.white70),
        ),
      ),
    ],
  );
}
