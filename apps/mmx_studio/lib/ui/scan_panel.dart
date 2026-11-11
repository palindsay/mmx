import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:mmx_core/mmx_core.dart';

import '../state/studio_state.dart';

class ScanPanel extends StatefulWidget {
  final StudioState state;
  const ScanPanel({super.key, required this.state});
  @override
  State<ScanPanel> createState() => _ScanPanelState();
}

class _ScanPanelState extends State<ScanPanel> {
  final form = GlobalKey<FormState>();
  StudioState get state => widget.state;
  int? hole, secondHole;
  bool smooth = false;
  double cutX = 0, cutY = 0, cutZ = 0, nx = 0, ny = 1, nz = 0;
  Widget number(
    String label,
    double value,
    ValueChanged<double> changed, {
    bool positive = true,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextFormField(
      initialValue: '$value',
      decoration: InputDecoration(labelText: label, isDense: true),
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      validator: (text) {
        final n = double.tryParse(text ?? '');
        return n == null || !n.isFinite || (positive && n <= 0)
            ? 'Enter a finite ${positive ? 'positive ' : ''}number'
            : null;
      },
      onChanged: (text) {
        final n = double.tryParse(text);
        if (n != null && n.isFinite) changed(n);
      },
    ),
  );
  Widget heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
  Widget action(String label, VoidCallback callback) => Padding(
    padding: const EdgeInsets.only(right: 6, bottom: 6),
    child: OutlinedButton(
      onPressed: state.interactionLocked
          ? null
          : () {
              if (form.currentState?.validate() ?? true) callback();
            },
      child: Text(label),
    ),
  );
  void startPreview(ScanStep step) {
    state.previewScan(step);
  }

  @override
  Widget build(BuildContext context) =>
      Material(type: MaterialType.transparency, child: _buildBody(context));

  Widget _buildBody(BuildContext context) {
    final preview = state.scanPreview;
    if (preview != null) {
      final d = preview.fromOriginal;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          heading('Review ${preview.step.operation}'),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show original'),
            subtitle: Text(
              state.scanPreviewShowOriginal
                  ? 'Original geometry in viewport'
                  : 'Proposed result in viewport',
            ),
            value: state.scanPreviewShowOriginal,
            onChanged: state.busy ? null : state.showScanOriginal,
          ),
          Text('${preview.result.mesh.faceCount} faces'),
          const SizedBox(height: 8),
          Text(
            'Compared with original: sampled max ${d.maximum.toStringAsFixed(3)} mm · RMS ${d.rms.toStringAsFixed(3)} mm · p95 ${d.p95.toStringAsFixed(3)} mm',
          ),
          const SizedBox(height: 8),
          Text(preview.result.note),
          const SizedBox(height: 8),
          const Text(
            'The original is retained when you apply. Sampled distances do not certify an error bound between samples.',
          ),
          if (preview.result.inferredGroup != null)
            Text(
              'Inferred surface: face group ${preview.result.inferredGroup}',
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: state.busy ? null : state.applyScanPreview,
            child: const Text('Apply scan edit'),
          ),
          TextButton(
            onPressed: state.busy ? null : state.cancelScanPreview,
            child: const Text('Cancel preview'),
          ),
        ],
      );
    }
    if (state.selected == null) {
      return const Text('Import or select a scanned mesh to begin.');
    }
    final report = state.scanReportCurrent ? state.scanReport : null;
    final holes =
        report?.defects.where((d) => d.kind == DefectKind.hole).toList() ??
        <MeshDefect>[];
    if (hole != null && hole! >= holes.length) hole = null;
    if (secondHole != null && secondHole! >= holes.length) secondHole = null;
    return Form(
      key: form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          heading('Scan to print'),
          const Text(
            'Mesh coordinates use millimeters. Confirm import units and printer settings before cleanup.',
          ),
          Wrap(
            children: [
              action('Inspect / preflight', state.inspectScan),
              action('Printer settings', _printerSettings),
              action('Export preflight report', () => _exportData()),
              if (state.selected!.scanSourceId != null)
                action('Compare original', state.compareScanOriginal),
            ],
          ),
          if (state.selected!.locked)
            const Text(
              'This is a protected original. Duplicate it from Modify to edit a copy.',
            ),
          if (report != null) ...[
            Text(
              '${report.dimensions.map((v) => v.toStringAsFixed(2)).join(' × ')} mm · ${report.components} components',
            ),
            heading('Findings (${report.findings.length})'),
            const Text(
              'Select a finding to highlight its region. Unknown checks require review.',
            ),
            for (final finding in report.findings.take(40))
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(switch (finding.severity) {
                  ScanSeverity.error => Icons.error_outline,
                  ScanSeverity.warning => Icons.warning_amber,
                  ScanSeverity.unknown => Icons.help_outline,
                }, size: 20),
                title: Text(finding.code),
                subtitle: Text(finding.message),
                onTap: () => state.selectScanFinding(finding),
              ),
            if (report.findings.length > 40)
              Text(
                '${report.findings.length - 40} more findings. Repair highlighted regions and inspect again.',
              ),
          ],
          heading('Cleanup with preview'),
          const Text(
            'A selected region limits denoising, Reduce and Remesh. For fragment removal it protects the selected components.',
          ),
          number(
            'Fragment area limit (mm²)',
            state.scanFragmentArea,
            (v) => state.scanFragmentArea = v,
          ),
          Wrap(
            children: [
              action(
                'Preview fragments',
                () => startPreview(
                  ScanStep('fragments', {'areaMm2': state.scanFragmentArea}),
                ),
              ),
              action(
                'Preview connectivity repair',
                () => startPreview(ScanStep('repair')),
              ),
            ],
          ),
          number(
            'Maximum denoise displacement (mm)',
            state.scanDisplacement,
            (v) => state.scanDisplacement = v,
          ),
          action(
            'Preview denoise',
            () => startPreview(
              ScanStep('denoise', {'displacementMm': state.scanDisplacement}),
            ),
          ),
          heading('Reduce and remesh'),
          number(
            'Sampled deviation limit (mm)',
            state.scanDeviationLimit,
            (v) => state.scanDeviationLimit = v,
          ),
          number(
            'Keep fraction (0–1)',
            state.scanKeepFraction,
            (v) => state.scanKeepFraction = v,
          ),
          action(
            'Preview reduction',
            () => startPreview(
              ScanStep('reduce', {
                'keepFraction': state.scanKeepFraction,
                'deviationMm': state.scanDeviationLimit,
              }),
            ),
          ),
          number(
            'Target edge length (mm)',
            state.scanEdgeLength,
            (v) => state.scanEdgeLength = v,
          ),
          action(
            'Preview remesh',
            () => startPreview(
              ScanStep('remesh', {
                'edgeMm': state.scanEdgeLength,
                'deviationMm': state.scanDeviationLimit,
              }),
            ),
          ),
          heading('Guided hole repair'),
          const Text(
            'Inspect first. Fill only unintended holes; all other openings remain unchanged. Added surfaces are marked as inferred.',
          ),
          DropdownButtonFormField<int>(
            key: ValueKey('hole-${holes.length}-$hole'),
            initialValue: hole,
            decoration: const InputDecoration(
              labelText: 'Boundary to fill',
              isDense: true,
            ),
            items: [
              for (var i = 0; i < holes.length; i++)
                DropdownMenuItem(
                  value: i,
                  child: Text(
                    'Hole ${i + 1} · ${holes[i].metric.toStringAsFixed(1)} mm',
                  ),
                ),
            ],
            onChanged: (v) {
              setState(() => hole = v);
              if (v != null) {
                state.selectScanFinding(
                  ScanFinding(
                    'hole',
                    '',
                    ScanSeverity.warning,
                    faces: holes[v].faces,
                  ),
                );
              }
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Smooth patch; keep boundary fixed'),
            value: smooth,
            onChanged: (v) => setState(() => smooth = v),
          ),
          if (hole != null)
            action(
              'Preview hole fill',
              () => startPreview(
                ScanStep('fillHole', {'loop': hole, 'smooth': smooth ? 1 : 0}),
              ),
            ),
          if (holes.length > 1) ...[
            DropdownButtonFormField<int>(
              key: ValueKey('second-hole-${holes.length}-$secondHole'),
              initialValue: secondHole,
              decoration: const InputDecoration(
                labelText: 'Second boundary for bridge',
                isDense: true,
              ),
              items: [
                for (var i = 0; i < holes.length; i++)
                  DropdownMenuItem(value: i, child: Text('Hole ${i + 1}')),
              ],
              onChanged: (v) => setState(() => secondHole = v),
            ),
            if (hole != null && secondHole != null && hole != secondHole)
              action(
                'Preview bridge',
                () => startPreview(
                  ScanStep('bridgeHoles', {
                    'first': hole,
                    'second': secondHole,
                  }),
                ),
              ),
          ],
          heading('Trim and prepare a base'),
          const Text(
            'Enter an arbitrary cutting plane. Keep the positive side and preview the capped result.',
          ),
          number('Plane point X (mm)', cutX, (v) => cutX = v, positive: false),
          number('Plane point Y (mm)', cutY, (v) => cutY = v, positive: false),
          number('Plane point Z (mm)', cutZ, (v) => cutZ = v, positive: false),
          number('Plane normal X', nx, (v) => nx = v, positive: false),
          number('Plane normal Y', ny, (v) => ny = v, positive: false),
          number('Plane normal Z', nz, (v) => nz = v, positive: false),
          action(
            'Preview trim',
            () => startPreview(
              ScanStep('trim', {
                'x': cutX,
                'y': cutY,
                'z': cutZ,
                'nx': nx,
                'ny': ny,
                'nz': nz,
              }),
            ),
          ),
          Wrap(
            children: [
              action('Drop to bed', state.doDropToBed),
              action('Arrange visible objects', state.packAll),
            ],
          ),
          number(
            'Cross-section layer height (mm)',
            state.printLayerHeight,
            (v) => state.printLayerHeight = v,
          ),
          action('Cross-section report', state.doSliceReport),
          if (state.selected!.scanHistory.isNotEmpty) ...[
            heading('Scan history'),
            Text(
              '${state.selected!.scanHistory.length} applied steps stored in this project. Undo restores the previous geometry and history.',
            ),
            action('Export cleanup recipe', () => _exportData(recipe: true)),
          ],
        ],
      ),
    );
  }

  Future<void> _exportData({bool recipe = false}) async {
    if (state.interactionLocked || state.scanPreview != null) return;
    final revision = state.doc.revision, selected = state.selectedObjectId;
    try {
      final location = await getSaveLocation(
        suggestedName: recipe ? 'cleanup.recipe.json' : 'scan.report.json',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (location == null || !mounted) return;
      if (await File(location.path).exists()) {
        if (!mounted) return;
        final replace = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Replace existing file?'),
            content: Text(location.path),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Replace'),
              ),
            ],
          ),
        );
        if (replace != true) return;
      }
      if (state.doc.revision != revision ||
          state.selectedObjectId != selected) {
        state.status = 'Scan changed while choosing a file; export again';
        state.notify();
        return;
      }
      await state.exportScanData(location.path, recipe: recipe);
    } catch (e) {
      state.status = 'Scan export failed: $e';
      state.notify();
    }
  }

  Future<void> _printerSettings() async {
    final p = state.printProfile;
    final width = TextEditingController(text: '${p.width}'),
        depth = TextEditingController(text: '${p.depth}'),
        height = TextEditingController(text: '${p.height}'),
        border = TextEditingController(text: '${p.border}'),
        wall = TextEditingController(text: '${p.minimumWall}'),
        angle = TextEditingController(text: '${p.overhangAngle}');
    var process = p.process;
    final key = GlobalKey<FormState>();
    try {
      final result = await showDialog<PrintProfile>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('Printer settings'),
            content: SingleChildScrollView(
              child: Form(
                key: key,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Set these values for your actual printer and material. Starting values are not printability guarantees.',
                    ),
                    DropdownButton<PrintProcess>(
                      value: process,
                      items: PrintProcess.values
                          .map(
                            (v) => DropdownMenuItem(
                              value: v,
                              child: Text(v.name.toUpperCase()),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => update(() => process = v!),
                    ),
                    for (final entry in [
                      ('Width (mm)', width),
                      ('Depth (mm)', depth),
                      ('Height (mm)', height),
                      ('Border (mm)', border),
                      ('Minimum wall (mm)', wall),
                      ('Overhang angle (degrees)', angle),
                    ])
                      TextFormField(
                        controller: entry.$2,
                        decoration: InputDecoration(labelText: entry.$1),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        validator: (s) {
                          final v = double.tryParse(s ?? '');
                          return v == null || !v.isFinite || v < 0
                              ? 'Enter a nonnegative finite number'
                              : null;
                        },
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (!key.currentState!.validate()) return;
                  final profile = PrintProfile(
                    process: process,
                    width: double.parse(width.text),
                    depth: double.parse(depth.text),
                    height: double.parse(height.text),
                    border: double.parse(border.text),
                    minimumWall: double.parse(wall.text),
                    overhangAngle: double.parse(angle.text),
                  );
                  try {
                    profile.validate();
                    Navigator.pop(context, profile);
                  } catch (e) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text('$e')));
                  }
                },
                child: const Text('Use settings'),
              ),
            ],
          ),
        ),
      );
      if (result != null) {
        state.printProfile = result;
        state.doc.revision++;
        state.dirty = true;
        state.scanReport = null;
        await state.render();
        state.notify();
      }
    } finally {
      for (final c in [width, depth, height, border, wall, angle]) {
        c.dispose();
      }
    }
  }
}
