import 'package:flutter/material.dart';
import 'package:mmx_core/mmx_core.dart';

import '../state/studio_state.dart';
import 'manipulator_controls.dart';
import 'material_panel.dart';
import 'renderer_controls.dart';
import 'scan_panel.dart';

/// Left tool rail, mirroring the shipped Meshmixer action bars
/// (Meshmix / Import / Select / Sculpt / Stamp / Edits / Analysis / Shaders /
/// Separate / Export / Print).
class LeftRail extends StatelessWidget {
  final StudioState state;
  const LeftRail({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    const items = <(StudioTool, IconData, String)>[
      (StudioTool.navigate, Icons.pan_tool_alt_outlined, 'Navigate'),
      (StudioTool.scan, Icons.document_scanner_outlined, 'Scan to print'),
      (StudioTool.select, Icons.highlight_alt, 'Select'),
      (StudioTool.sculpt, Icons.brush_outlined, 'Sculpt'),
      (StudioTool.stamp, Icons.approval_outlined, 'Stamp'),
      (StudioTool.planeCut, Icons.content_cut, 'Plane Cut'),
      (StudioTool.mirror, Icons.flip, 'Mirror'),
      (StudioTool.extrude, Icons.open_in_full, 'Extrude'),
      (StudioTool.separate, Icons.call_split, 'Separate Shells'),
      (StudioTool.remesh, Icons.grid_on, 'Remesh'),
      (StudioTool.reduce, Icons.compress, 'Reduce'),
      (StudioTool.makeSolid, Icons.hexagon_outlined, 'Make Solid'),
      (StudioTool.hollow, Icons.donut_large, 'Hollow'),
      (StudioTool.analysis, Icons.analytics_outlined, 'Analysis'),
      (StudioTool.supports, Icons.foundation_outlined, 'Supports'),
      (StudioTool.modify, Icons.auto_fix_high, 'Modify'),
      (StudioTool.print, Icons.view_in_ar_outlined, 'Print / Layout'),
    ];
    return Container(
      width: 58,
      color: const Color(0xFF1B1E22),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final item in items)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 2,
                      horizontal: 6,
                    ),
                    child: Semantics(
                      label: item.$3,
                      button: true,
                      selected: state.tool == item.$1,
                      child: Tooltip(
                        excludeFromSemantics: true,
                        message: item.$3,
                        child: Material(
                          color: state.tool == item.$1
                              ? Theme.of(context).colorScheme.primary
                                    .withValues(alpha: 0.25)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => state.setTool(item.$1),
                            child: SizedBox(
                              height: 40,
                              child: Icon(
                                item.$2,
                                size: 21,
                                color: state.tool == item.$1
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.white70,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Wireframe',
            icon: Icon(
              Icons.grid_4x4,
              semanticLabel: 'Wireframe',
              color: state.wireframe ? Colors.tealAccent : Colors.white38,
            ),
            onPressed: state.toggleWireframe,
          ),
          IconButton(
            tooltip: 'Print bed',
            icon: Icon(
              Icons.crop_free,
              semanticLabel: 'Print bed',
              color: state.showBed ? Colors.tealAccent : Colors.white38,
            ),
            onPressed: state.toggleBed,
          ),
          IconButton(
            tooltip: 'Frame selection',
            icon: const Icon(
              Icons.center_focus_strong,
              color: Colors.white54,
              semanticLabel: 'Frame selection',
            ),
            onPressed: state.frameSelection,
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

/// Right-hand properties panel. Contents change with the active tool.
class PropertiesPanel extends StatelessWidget {
  final StudioState state;
  const PropertiesPanel({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 330,
      color: const Color(0xFF1B1E22),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
        children: [
          _SceneSection(state: state),
          const Divider(height: 26),
          if (state.tool == StudioTool.navigate ||
              state.tool == StudioTool.modify)
            ManipulatorControls(state: state),
          if (state.tool == StudioTool.navigate ||
              state.tool == StudioTool.modify)
            MaterialPanel(state: state),
          ..._toolSection(context),
        ],
      ),
    );
  }

  List<Widget> _toolSection(BuildContext context) {
    switch (state.tool) {
      case StudioTool.scan:
        return [ScanPanel(state: state)];
      case StudioTool.navigate:
        return <Widget>[
          _sectionTitle('View'),
          RendererControls(state: state),
          _kv('Camera', 'orbit / shift-drag pan / scroll zoom'),
          _kv('Objects', '${state.doc.objects.length}'),
          _kv('Undo depth', '${state.doc.undoDepth}'),
          _kv(
            'Memory',
            '${(state.doc.memoryBytes / 1e6).toStringAsFixed(1)} MB',
          ),
        ];
      case StudioTool.select:
        return <Widget>[
          _sectionTitle('Selection'),
          _slider(
            'Brush radius',
            state.brushRadius,
            0.5,
            80,
            (v) => state.brushRadius = v,
          ),
          Row(
            children: [
              _button(context, 'All', state.selectAll),
              _button(context, 'Expand', state.expandSelection),
              _button(context, 'Contract', state.contractSelection),
              _button(context, 'Clear', state.clearSelection),
            ],
          ),
          const SizedBox(height: 8),
          _kv('Selected faces', '${state.selection?.count ?? 0}'),
          const SizedBox(height: 8),
          _sectionTitle('Selection actions'),
          Row(
            children: [
              _button(context, 'Discard', _discardSelection),
              _button(
                context,
                'Remesh',
                () => state.doRemesh(selectionOnly: true),
              ),
              _button(
                context,
                'Reduce',
                () => state.doReduce(selectionOnly: true),
              ),
            ],
          ),
          Row(
            children: [
              _button(context, 'Extract', _extractSelection),
              _button(context, 'Make Part', _makePart),
              _button(context, 'Pivot', state.doCreatePivot),
              _button(context, 'Smooth', _smoothSelection),
            ],
          ),
        ];
      case StudioTool.sculpt:
        return <Widget>[
          _sectionTitle('Brush'),
          DropdownButtonFormField<BrushOp>(
            initialValue: state.brushOp,
            decoration: const InputDecoration(labelText: 'Type', isDense: true),
            items: BrushOp.values
                .map((op) => DropdownMenuItem(value: op, child: Text(op.name)))
                .toList(),
            onChanged: (v) => state.brushOp = v ?? BrushOp.draw,
          ),
          const SizedBox(height: 8),
          _slider(
            'Size',
            state.brushRadius,
            0.5,
            80,
            (v) => state.brushRadius = v,
          ),
          _slider(
            'Strength',
            state.brushStrength,
            0.02,
            1.0,
            (v) => state.brushStrength = v,
          ),
          _kv('Secondary (right drag)', 'smooth'),
          const SizedBox(height: 6),
          const Text(
            'Left-drag on the surface to sculpt. Dynamic refinement splits '
            'edges inside the brush as you go.',
            style: TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ];
      case StudioTool.stamp:
        return <Widget>[
          _sectionTitle('Stamp'),
          DropdownButtonFormField<StampPattern>(
            initialValue: state.stampPattern,
            decoration: const InputDecoration(
              labelText: 'Pattern',
              isDense: true,
            ),
            items: StampPattern.values
                .map((p) => DropdownMenuItem(value: p, child: Text(p.name)))
                .toList(),
            onChanged: (v) => state.stampPattern = v ?? StampPattern.circle,
          ),
          const SizedBox(height: 8),
          _slider(
            'Radius',
            state.stampRadius,
            1,
            40,
            (v) => state.stampRadius = v,
          ),
          _slider(
            'Height',
            state.stampHeight,
            0.2,
            10,
            (v) => state.stampHeight = v,
          ),
          const SizedBox(height: 6),
          const Text(
            'Displaces the surface with an analytic height field. Applies at '
            'the selection centroid, or the topmost vertex when nothing is '
            'selected.',
            style: TextStyle(fontSize: 11, color: Colors.white54),
          ),
          const SizedBox(height: 8),
          _button(context, 'Apply stamp', state.doStamp),
        ];
      case StudioTool.planeCut:
        return <Widget>[
          _sectionTitle('Plane Cut'),
          DropdownButton<int>(
            value: state.planeAxis,
            items: [
              for (var i = 0; i < 3; i++)
                DropdownMenuItem(value: i, child: Text(['X', 'Y', 'Z'][i])),
            ],
            onChanged: (v) {
              state.planeAxis = v!;
              state.notify();
            },
          ),
          SwitchListTile(
            title: const Text('Keep positive side'),
            value: state.planeKeepPositive,
            onChanged: (v) {
              state.planeKeepPositive = v;
              state.notify();
            },
          ),
          _slider(
            'Offset',
            state.planeOffset,
            -50,
            50,
            (v) => state.planeOffset = v,
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Fill cut', style: TextStyle(fontSize: 13)),
            value: state.planeFill,
            onChanged: (v) => state.planeFill = v,
          ),
          const SizedBox(height: 6),
          _button(context, 'Apply cut', state.doPlaneCut),
        ];
      case StudioTool.mirror:
        return <Widget>[
          _sectionTitle('Mirror'),
          _slider(
            'Plane offset X',
            state.mirrorPlaneOffset,
            -60,
            60,
            (v) => state.mirrorPlaneOffset = v,
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Keep original', style: TextStyle(fontSize: 13)),
            value: state.mirrorKeepOriginal,
            onChanged: (v) {
              state.mirrorKeepOriginal = v;
              state.notify();
            },
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Weld seam', style: TextStyle(fontSize: 13)),
            value: state.mirrorWeld,
            onChanged: (v) {
              state.mirrorWeld = v;
              state.notify();
            },
          ),
          const SizedBox(height: 6),
          _button(context, 'Mirror', state.doMirror),
        ];
      case StudioTool.extrude:
        return <Widget>[
          _sectionTitle('Extrude'),
          _slider(
            'Distance',
            state.extrudeDistance,
            0.5,
            40,
            (v) => state.extrudeDistance = v,
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Smooth boundary',
              style: TextStyle(fontSize: 13),
            ),
            value: state.extrudeSmooth,
            onChanged: (v) {
              state.extrudeSmooth = v;
              state.notify();
            },
          ),
          const SizedBox(height: 6),
          _kv('Selected faces', '${state.selection?.count ?? 0}'),
          const SizedBox(height: 6),
          _button(context, 'Extrude selection', state.doExtrude),
          const SizedBox(height: 8),
          const Text(
            'Select a region first (Select tool), then extrude it along the '
            'surface normal. A skirt is built from the selection boundary.',
            style: TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ];
      case StudioTool.separate:
        return <Widget>[
          _sectionTitle('Separate Shells'),
          _kv('Objects', '${state.doc.objects.length}'),
          _kv('Shells in selection', '${state.shellCount}'),
          const SizedBox(height: 8),
          _button(context, 'Separate shells', state.doSeparateShells),
          const SizedBox(height: 8),
          const Text(
            'Splits every disconnected shell into its own scene object, '
            'largest first.',
            style: TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ];
      case StudioTool.remesh:
        return <Widget>[
          _sectionTitle('Remesh'),
          _slider(
            'Density',
            state.remeshDensity,
            0.05,
            1.0,
            (v) => state.remeshDensity = v,
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Preserve group boundaries',
              style: TextStyle(fontSize: 13),
            ),
            value: state.remeshGroupAware,
            onChanged: (v) {
              state.remeshGroupAware = v;
              state.notify();
            },
          ),
          const SizedBox(height: 6),
          const Text(
            'Isotropic remeshing: split long edges, collapse short ones, '
            'flip to valence six, relax tangentially and reproject. With '
            'group boundaries on, the remesher pins internal group seams '
            '(VariationalRemesher behaviour).',
            style: TextStyle(fontSize: 11, color: Colors.white54),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _button(context, 'Face groups', state.doGenerateFaceGroups),
              _button(
                context,
                'Remesh',
                () => state.doRemesh(groupAware: state.remeshGroupAware),
              ),
            ],
          ),
        ];
      case StudioTool.reduce:
        return <Widget>[
          _sectionTitle('Reduce'),
          _slider(
            'Keep fraction',
            state.reducePercent,
            0.02,
            0.95,
            (v) => state.reducePercent = v,
          ),
          _kv(
            'Target faces',
            '${(state.activeMesh?.faceCount ?? 0) * state.reducePercent ~/ 1}',
          ),
          const SizedBox(height: 8),
          _button(context, 'Reduce', state.doReduce),
        ];
      case StudioTool.makeSolid:
        return <Widget>[
          _sectionTitle('Make Solid'),
          DropdownButtonFormField<SolidMode>(
            initialValue: state.solidMode,
            decoration: const InputDecoration(
              labelText: 'Routine',
              isDense: true,
            ),
            items: SolidMode.values
                .map((m) => DropdownMenuItem(value: m, child: Text(m.name)))
                .toList(),
            onChanged: (v) => state.solidMode = v ?? SolidMode.accurate,
          ),
          _slider(
            'Grid resolution',
            state.solidResolution,
            32,
            256,
            (v) => state.solidResolution = v,
          ),
          _slider(
            'Offset',
            state.solidOffset,
            -20,
            20,
            (v) => state.solidOffset = v,
          ),
          _slider(
            'Smoothing',
            state.solidSmoothing.toDouble(),
            0,
            8,
            (v) => state.solidSmoothing = v.round(),
          ),
          _slider(
            'Minimum wall check (mm; 0 = off)',
            state.solidMinThickness,
            0,
            20,
            (v) => state.solidMinThickness = v,
          ),
          const Text(
            'Checks inward-normal clearance and may grow the model. '
            'Use Accurate or Blocky; verified edits bake object transforms.',
            style: TextStyle(fontSize: 11, color: Colors.white54),
          ),
          const SizedBox(height: 8),
          _button(context, 'Make Solid', state.doMakeSolid),
        ];
      case StudioTool.hollow:
        return <Widget>[
          _sectionTitle('Hollow'),
          _slider(
            'Wall thickness',
            state.hollowThickness,
            0.4,
            20,
            (v) => state.hollowThickness = v,
          ),
          _slider(
            'Escape holes',
            state.hollowHoles.toDouble(),
            0,
            8,
            (v) => state.hollowHoles = v.round(),
          ),
          _slider(
            'Grid resolution',
            state.solidResolution,
            32,
            256,
            (v) => state.solidResolution = v,
          ),
          _slider(
            'Minimum wall check (mm; 0 = off)',
            state.hollowMinThickness,
            0,
            20,
            (v) => state.hollowMinThickness = v,
          ),
          const Text(
            'Checks inward-normal clearance for enclosed shells only '
            '(zero escape holes). May thicken the wall and bake transforms.',
            style: TextStyle(fontSize: 11, color: Colors.white54),
          ),
          const SizedBox(height: 8),
          _button(context, 'Hollow', state.doHollow),
        ];
      case StudioTool.modify:
        return <Widget>[
          _sectionTitle('Surface'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _button(context, 'Flip normals', state.doFlipNormals),
              _button(context, 'Smooth', state.doSmoothMesh),
              _button(context, 'Stitch cracks', state.doStitchCracks),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Flip normals honours the current face selection; Smooth is '
            'Taubin (volume preserving) over the whole mesh.',
            style: TextStyle(fontSize: 11, color: Colors.white54),
          ),
          const SizedBox(height: 10),
          _sectionTitle('Placement'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _button(context, 'Drop to bed', state.doDropToBed),
              _button(context, 'Center on bed', state.doCenterOnBed),
            ],
          ),
          const SizedBox(height: 10),
          _sectionTitle('Object'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _button(context, 'Duplicate', state.doDuplicate),
              _button(context, 'Combine all', state.doCombineAll),
            ],
          ),
          const SizedBox(height: 8),
          _slider(
            'Pattern columns',
            state.patternCountX.toDouble(),
            1,
            8,
            (v) => state.patternCountX = v.round(),
          ),
          _slider(
            'Pattern rows',
            state.patternCountZ.toDouble(),
            1,
            8,
            (v) => state.patternCountZ = v.round(),
          ),
          _slider(
            'Pattern gap',
            state.patternGap,
            0.5,
            20,
            (v) => state.patternGap = v,
          ),
          _button(context, 'Make pattern', state.doMakePattern),
          const SizedBox(height: 10),
          _sectionTitle('Primitive'),
          DropdownButtonFormField<PrimitiveKind>(
            initialValue: state.primitiveKind,
            decoration: const InputDecoration(labelText: 'Fit', isDense: true),
            items: PrimitiveKind.values
                .map((k) => DropdownMenuItem(value: k, child: Text(k.name)))
                .toList(),
            onChanged: (v) {
              state.primitiveKind = v ?? PrimitiveKind.box;
              state.notify();
            },
          ),
          const SizedBox(height: 4),
          _button(context, 'Replace with primitive', state.doFitPrimitive),
          const SizedBox(height: 10),
          _sectionTitle('Measure'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _button(context, 'Measure', state.doMeasure),
              _button(context, 'Clearance', state.doClearance),
            ],
          ),
          const SizedBox(height: 10),
          _sectionTitle('Align'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _button(context, 'Align to target', state.doAlignToTarget),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Rigid ICP onto the first other object in the scene. Use it to '
            'register a scan or a duplicated part onto its reference.',
            style: TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ];
      case StudioTool.analysis:
        return <Widget>[
          _sectionTitle('Analysis'),
          _slider(
            'Thickness threshold',
            state.thicknessThreshold,
            0.1,
            20,
            (v) => state.thicknessThreshold = v,
          ),
          _slider(
            'Overhang angle',
            state.overhangAngle,
            10,
            80,
            (v) => state.overhangAngle = v,
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _button(
                context,
                'Thickness',
                () => state.doAnalysis(AnalysisOverlay.thickness),
              ),
              _button(
                context,
                'Overhang',
                () => state.doAnalysis(AnalysisOverlay.overhang),
              ),
              _button(
                context,
                'Stability',
                () => state.doAnalysis(AnalysisOverlay.stability),
              ),
              _button(
                context,
                'Clear',
                () => state.doAnalysis(AnalysisOverlay.none),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _sectionTitle('Repair'),
          Row(
            children: [
              _button(context, 'Inspector', state.inspectMesh),
              _button(context, 'Auto repair', state.autoRepair),
            ],
          ),
        ];
      case StudioTool.supports:
        return <Widget>[
          _sectionTitle('Supports'),
          _slider(
            'Overhang angle',
            state.supportAngle,
            10,
            80,
            (v) => state.supportAngle = v,
          ),
          _slider(
            'Density',
            state.supportDensity,
            0.05,
            1.0,
            (v) => state.supportDensity = v,
          ),
          const SizedBox(height: 8),
          _button(context, 'Generate support forest', state.doSupports),
          const SizedBox(height: 8),
          const Text(
            'Tapered posts with base discs plus struts that respect the '
            'maximum strut angle. Generated as a separate object.',
            style: TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ];
      case StudioTool.print:
        return <Widget>[
          _sectionTitle('Print / Layout'),
          _kv('Bed', '200 x 200 mm'),
          const SizedBox(height: 6),
          _button(context, 'Pack objects on bed', _packAll),
          const SizedBox(height: 6),
          _button(context, 'Slice report', _sliceReport),
        ];
    }
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.1,
      ),
    ),
  );

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(k, style: const TextStyle(fontSize: 12, color: Colors.white60)),
        Flexible(
          child: Text(
            v,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    ),
  );

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    void Function(double) onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
            Text(
              value.toStringAsFixed(2),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        MergeSemantics(
          child: Semantics(
            label: label,
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: (v) {
                onChanged(v);
                state.notify();
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _button(
    BuildContext context,
    String label,
    Future<void> Function() fn,
  ) {
    return Padding(
      padding: const EdgeInsets.only(right: 4, bottom: 4),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          textStyle: const TextStyle(fontSize: 11),
        ),
        onPressed: state.interactionLocked ? null : () => fn(),
        child: Text(label),
      ),
    );
  }

  Future<void> _discardSelection() => state.discardSelection();
  Future<void> _extractSelection() => state.extractSelection();
  Future<void> _makePart() => state.makePart();
  Future<void> _smoothSelection() => state.smoothSelection();
  Future<void> _packAll() => state.packAll();
  Future<void> _sliceReport() => state.doSliceReport();
}

class _SceneSection extends StatelessWidget {
  final StudioState state;
  const _SceneSection({required this.state});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'OBJECTS',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 6),
        for (final o in state.doc.objects)
          InkWell(
            onTap: () {
              state.selectedObjectId = o.id;
              state.selection = null;
              state.notify();
              state.render();
            },
            child: Container(
              margin: const EdgeInsets.only(bottom: 3),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: o.id == state.selectedObjectId
                    ? Theme.of(context).colorScheme.primary
                          .withValues(alpha: 0.18)
                    : Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(
                    o.id == state.selectedObjectId
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 14,
                    color: Colors.white54,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      o.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  Text(
                    '${o.mesh.faceCount}',
                    style: const TextStyle(fontSize: 10, color: Colors.white38),
                  ),
                  if (o.locked)
                    const Icon(
                      Icons.lock_outline,
                      size: 14,
                      semanticLabel: 'Protected original',
                    ),
                  PopupMenuButton<String>(
                    tooltip: 'Actions for ${o.name}',
                    icon: const Icon(Icons.more_horiz, size: 18),
                    onSelected: (action) async {
                      if (action == 'rename') {
                        final controller = TextEditingController(text: o.name);
                        final name = await showDialog<String>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Rename object'),
                            content: TextField(
                              controller: controller,
                              autofocus: true,
                              maxLength: 256,
                              decoration: const InputDecoration(
                                labelText: 'Object name',
                              ),
                              onSubmitted: (value) =>
                                  Navigator.pop(context, value),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () =>
                                    Navigator.pop(context, controller.text),
                                child: const Text('Rename'),
                              ),
                            ],
                          ),
                        );
                        controller.dispose();
                        if (name != null) {
                          await state.sceneAction(o.id, action, name: name);
                        }
                      } else {
                        await state.sceneAction(o.id, action);
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'rename',
                        child: Text('Rename…'),
                      ),
                      PopupMenuItem(
                        value: 'visibility',
                        child: Text(o.visible ? 'Hide' : 'Show'),
                      ),
                      const PopupMenuItem(
                        value: 'isolate',
                        child: Text('Isolate'),
                      ),
                      const PopupMenuItem(
                        value: 'showAll',
                        child: Text('Show editable objects'),
                      ),
                      PopupMenuItem(
                        value: 'target',
                        enabled: !o.locked,
                        child: Text(
                          o.isTarget
                              ? 'Clear reference target'
                              : 'Use as reference target',
                        ),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: 'delete',
                        enabled:
                            !o.locked &&
                            !state.doc.objects.any(
                              (item) => item.scanSourceId == o.id,
                            ),
                        child: const Text('Delete object'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
