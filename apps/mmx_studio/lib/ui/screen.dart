import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mmx_core/mmx_core.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/studio_state.dart';
import '../state/recovery_store.dart';
import 'panels.dart';
import 'viewport.dart';

class StudioScreen extends StatefulWidget {
  final StudioTool? initialTool;
  final StudioState? state;
  final bool enableRecovery;
  final Future<Directory> Function()? recoveryDirectory;
  const StudioScreen({
    super.key,
    this.initialTool,
    this.state,
    this.enableRecovery = true,
    this.recoveryDirectory,
  });

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  late final StudioState state = widget.state ?? StudioState();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  String? _lastDirectory;
  RecoveryStore? _recovery;
  Timer? _autosave;
  AppLifecycleListener? _lifecycle;
  bool _savingRecovery = false;
  Future<void>? _recoveryTask;
  bool _exitPending = false;
  bool _projectTransitionPending = false;

  Future<void> _initializeRecovery() async {
    try {
      final dir =
          await (widget.recoveryDirectory ?? getApplicationSupportDirectory)();
      final store = await RecoveryStore.open(dir);
      _recovery = store;
      if (!mounted) {
        await store.close();
        return;
      }
      final candidate = await store.claimNext();
      if (candidate != null) {
        try {
          final modified = await File(candidate.path).lastModified();
          if (!mounted) return;
          final decision = await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Recover unsaved project?'),
              content: Text('Last saved ${modified.toLocal()}'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, 'keep'),
                  child: const Text('Keep for later'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, 'discard'),
                  child: const Text('Discard recovery'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, 'recover'),
                  child: const Text('Recover'),
                ),
              ],
            ),
          );
          if (!mounted) return;
          if (decision == 'recover') {
            final recovered = await candidate.withPath(
              (path) => state.openProject(path, asRecovery: true),
            );
            if (recovered && mounted) {
              final revision = state.doc.revision;
              try {
                // Keep the prior session's recovery until this session has a
                // complete copy. An intervening edit leaves the prior copy too.
                _recoveryTask = store.withPath(state.autosave);
                await _recoveryTask;
                if (mounted &&
                    state.doc.revision == revision &&
                    await File(store.path).exists()) {
                  await candidate.clear();
                }
              } catch (e) {
                state.status = 'Recovery copy failed: $e';
                state.notify();
              }
            }
          } else if (decision == 'discard') {
            await candidate.clear();
          }
        } finally {
          await candidate.release();
        }
      }
      if (!mounted) return;
      _autosave = Timer.periodic(const Duration(seconds: 30), (_) async {
        if (_savingRecovery || _exitPending || _projectTransitionPending) {
          return;
        }
        _savingRecovery = true;
        try {
          _recoveryTask = store.withPath(state.autosave);
          await _recoveryTask;
        } catch (e) {
          state.status = 'Recovery save failed: $e';
          state.notify();
        } finally {
          _savingRecovery = false;
        }
      });
    } catch (e) {
      state.status = 'Recovery unavailable: $e';
      state.notify();
    }
  }

  Future<bool> _clearRecovery({
    int? expectedRevision,
    bool allowDirty = false,
  }) async {
    final store = _recovery;
    if (store == null) return true;
    final revision = expectedRevision ?? state.doc.revision;
    bool stillSafeToClear() =>
        state.doc.revision == revision &&
        !state.interactionLocked &&
        (allowDirty || !state.dirty);
    try {
      // Queue cleanup behind this session's writes, then recheck whether the
      // user has made a newer edit while a prior recovery write was settling.
      return await store.withPath((path) async {
        if (!stillSafeToClear()) return false;
        final file = File(path);
        final exists = await file.exists();
        if (!stillSafeToClear()) return false;
        if (exists) await file.delete();
        return true;
      });
    } catch (e) {
      state.status = 'Recovery cleanup failed: $e';
      state.notify();
      return false;
    }
  }

  Future<void> _closeRecovery() async {
    try {
      // Closing waits for queued reads/writes and never deletes recovery data.
      await _recovery?.close();
    } catch (_) {
      // A disposed screen cannot present cleanup errors. The OS also releases
      // the session lease when its process exits.
    }
  }

  Future<bool> _confirmDiscard({String? before}) async {
    if (state.scanPreview != null) {
      state.status =
          'Apply or cancel the scan preview before changing projects';
      state.notify();
      return false;
    }
    if (state.interactionLocked) return false;
    if (!state.dirty) return true;
    final revision = state.doc.revision;
    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          before == null ? 'Save changes?' : 'Save changes before $before?',
        ),
        content: Text(
          'Your changes to ${state.projectPath == null ? 'this untitled project' : '“${state.projectPath!.split(RegExp(r'[/\\]')).last}”'} '
          'will be lost if you discard them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('Discard'),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (answer == 'save') {
      return await _saveProject() && !state.dirty && !state.interactionLocked;
    }
    return answer == 'discard' &&
        state.doc.revision == revision &&
        !state.interactionLocked;
  }

  @override
  void initState() {
    super.initState();
    if (widget.enableRecovery) _initializeRecovery();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        if (_exitPending || _projectTransitionPending) {
          return AppExitResponse.cancel;
        }
        _exitPending = true;
        final revision = state.doc.revision;
        try {
          if (!await _confirmDiscard()) return AppExitResponse.cancel;
          await _clearRecovery(expectedRevision: revision, allowDirty: true);
          if (state.doc.revision != revision || state.interactionLocked) {
            return AppExitResponse.cancel;
          }
          _autosave?.cancel();
          return AppExitResponse.exit;
        } finally {
          _exitPending = false;
        }
      },
    );
    final initial = widget.initialTool;
    if (initial != null) {
      state.setTool(initial);
    }
  }

  @override
  void dispose() {
    _autosave?.cancel();
    unawaited(_closeRecovery());
    _lifecycle?.dispose();
    if (widget.state == null) state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final narrow = MediaQuery.sizeOf(context).width < 900;
        final useMeta = Theme.of(context).platform == TargetPlatform.macOS;
        return CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.escape): () {
              state.cancelInteraction();
            },
            SingleActivator(
              LogicalKeyboardKey.keyZ,
              control: !useMeta,
              meta: useMeta,
            ): () =>
                state.undo(),
            SingleActivator(
              LogicalKeyboardKey.keyZ,
              control: !useMeta,
              meta: useMeta,
              shift: true,
            ): () =>
                state.redo(),
            SingleActivator(
              LogicalKeyboardKey.keyY,
              control: !useMeta,
              meta: useMeta,
            ): () =>
                state.redo(),
            SingleActivator(
              LogicalKeyboardKey.keyN,
              control: !useMeta,
              meta: useMeta,
            ): () =>
                _newProject(),
            SingleActivator(
              LogicalKeyboardKey.keyO,
              control: !useMeta,
              meta: useMeta,
            ): () =>
                _showImport(context),
            SingleActivator(
              LogicalKeyboardKey.keyS,
              control: !useMeta,
              meta: useMeta,
            ): () =>
                _saveProject(),
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              key: _scaffoldKey,
              endDrawer: narrow
                  ? Drawer(
                      width: 330,
                      child: AbsorbPointer(
                        absorbing: state.interactionLocked,
                        child: PropertiesPanel(state: state),
                      ),
                    )
                  : null,
              appBar: AppBar(
                toolbarHeight: 46,
                backgroundColor: const Color(0xFF1B1E22),
                titleSpacing: 12,
                title: Row(
                  children: [
                    const Icon(
                      Icons.hub_outlined,
                      size: 18,
                      color: Colors.tealAccent,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'MESH STUDIO',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.4,
                      ),
                    ),
                    if (state.dirty)
                      const Text(' *', semanticsLabel: 'Unsaved changes'),
                    const SizedBox(width: 16),
                    if (state.busy)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        state.operationPhase == null
                            ? state.status
                            : '${state.status} · ${state.operationPhase}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                  ],
                ),
                actions: [
                  if (state.busy)
                    IconButton(
                      tooltip: 'Cancel operation',
                      icon: const Icon(
                        Icons.cancel_outlined,
                        semanticLabel: 'Cancel operation',
                      ),
                      onPressed: state.cancelInteraction,
                    ),
                  PopupMenuButton<String>(
                    tooltip: 'Project',
                    enabled: !state.interactionLocked,
                    onSelected: (action) async {
                      if (action == 'new') await _newProject();
                      if (action == 'save') await _saveProject();
                      if (action == 'saveAs') await _saveProject(saveAs: true);
                      if (action == 'open') await _openProject();
                      if (action == 'transform') await _transform();
                      if (action == 'boolean') await _boolean();
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'new',
                        child: Row(
                          children: [
                            const Expanded(child: Text('New project')),
                            const SizedBox(width: 12),
                            Text(
                              useMeta ? '⌘N' : 'Ctrl+N',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'open',
                        child: Text('Open project…'),
                      ),
                      const PopupMenuItem(
                        value: 'save',
                        child: Text('Save project'),
                      ),
                      const PopupMenuItem(
                        value: 'saveAs',
                        child: Text('Save project as…'),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'transform',
                        child: Text('Transform selected…'),
                      ),
                      const PopupMenuItem(
                        value: 'boolean',
                        child: Text('Boolean…'),
                      ),
                    ],
                    child: Semantics(
                      button: true,
                      enabled: !state.interactionLocked,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Opacity(
                          opacity: state.interactionLocked ? 0.38 : 1,
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('Project'),
                              Icon(Icons.arrow_drop_down, size: 18),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Undo',
                    icon: const Icon(
                      Icons.undo,
                      size: 18,
                      semanticLabel: 'Undo',
                    ),
                    onPressed: !state.interactionLocked && state.doc.canUndo
                        ? () => state.undo()
                        : null,
                  ),
                  IconButton(
                    tooltip: 'Redo',
                    icon: const Icon(
                      Icons.redo,
                      size: 18,
                      semanticLabel: 'Redo',
                    ),
                    onPressed: !state.interactionLocked && state.doc.canRedo
                        ? () => state.redo()
                        : null,
                  ),
                  IconButton(
                    tooltip: 'Import mesh',
                    icon: const Icon(
                      Icons.file_open_outlined,
                      size: 18,
                      semanticLabel: 'Import mesh',
                    ),
                    onPressed: state.interactionLocked
                        ? null
                        : () => _showImport(context),
                  ),
                  IconButton(
                    tooltip: 'Export selected',
                    icon: const Icon(
                      Icons.save_outlined,
                      size: 18,
                      semanticLabel: 'Export selected',
                    ),
                    onPressed: state.interactionLocked
                        ? null
                        : () => _showExport(context),
                  ),
                  if (narrow)
                    IconButton(
                      tooltip: 'Tool properties',
                      icon: const Icon(
                        Icons.tune,
                        size: 18,
                        semanticLabel: 'Tool properties',
                      ),
                      onPressed: () =>
                          _scaffoldKey.currentState?.openEndDrawer(),
                    ),
                  const SizedBox(width: 8),
                ],
              ),
              body: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 900;
                  return Row(
                    children: [
                      AbsorbPointer(
                        absorbing: state.interactionLocked,
                        child: LeftRail(state: state),
                      ),
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            MeshViewport(state: state),
                            if (state.doc.objects.isEmpty && !state.busy)
                              _EmptyProject(
                                onImport: () => _showImport(context),
                                onOpen: _openProject,
                              ),
                          ],
                        ),
                      ),
                      if (!compact)
                        AbsorbPointer(
                          absorbing: state.interactionLocked,
                          child: PropertiesPanel(state: state),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showImport(BuildContext context) async {
    if (state.interactionLocked) return;
    try {
      final file = await openFile(
        initialDirectory: _lastDirectory,
        acceptedTypeGroups: [
          const XTypeGroup(label: 'Mesh', extensions: MeshIO.importExtensions),
        ],
      );
      if (file == null) return;
      var unitScale = 1.0;
      if ([
        'obj',
        'stl',
        'ply',
        'off',
      ].contains(file.path.toLowerCase().split('.').last)) {
        if (!context.mounted) return;
        final units = await showDialog<double>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Units used by this mesh'),
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'This format does not specify units. Coordinates are converted to millimeters.',
                ),
              ),
              for (final entry in const {
                'Millimeters': 1.0,
                'Centimeters': 10.0,
                'Meters': 1000.0,
                'Inches': 25.4,
                'Feet': 304.8,
              }.entries)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, entry.value),
                  child: Text(entry.key),
                ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
        );
        if (units == null) return;
        unitScale = units;
      }
      await state.importPath(file.path, unitScale: unitScale);
      _lastDirectory = File(file.path).parent.path;
    } catch (e) {
      state.status = 'Import failed: $e';
      state.notify();
    }
  }

  Future<bool> _confirmReplace(String path) async {
    if (!await File(path).exists()) return true;
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Replace existing file?'),
            content: Text(
              'The file at $path already exists. Replacing it cannot be undone.',
            ),
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
        ) ==
        true;
  }

  Future<void> _showExport(BuildContext context) async {
    if (state.interactionLocked || state.selected == null) return;
    try {
      final file = await getSaveLocation(
        initialDirectory: _lastDirectory,
        suggestedName: 'mesh.stl',
        acceptedTypeGroups: [
          const XTypeGroup(label: 'Mesh', extensions: MeshIO.exportExtensions),
        ],
      );
      if (file == null) return;
      if (!await _confirmReplace(file.path)) return;
      if (file.path.toLowerCase().endsWith('.mix')) {
        if (!context.mounted) return;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Export geometry to Meshmixer'),
            content: const Text(
              'This export contains the selected geometry. Original opaque Meshmixer records are retained only in the saved .mmx project, not copied into this edited export.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Export'),
              ),
            ],
          ),
        );
        if (proceed != true) return;
      }
      await state.exportSelected(file.path);
      _lastDirectory = File(file.path).parent.path;
    } catch (e) {
      state.status = 'Export failed: $e';
      state.notify();
    }
  }

  Future<bool> _saveProject({bool saveAs = false}) async {
    if (state.interactionLocked) return false;
    try {
      var path = saveAs ? null : state.projectPath;
      final choosingPath = path == null;
      path ??= (await getSaveLocation(
        initialDirectory: _lastDirectory,
        suggestedName: 'project.mmx',
        acceptedTypeGroups: [
          const XTypeGroup(label: 'mmx project', extensions: ['mmx']),
        ],
      ))?.path;
      if (path == null) return false;
      if (choosingPath && !await _confirmReplace(path)) return false;
      final savedRevision = state.doc.revision;
      final saved = await state.saveProject(path);
      if (saved) {
        await _clearRecovery(expectedRevision: savedRevision);
        _lastDirectory = File(path).parent.path;
      }
      return saved;
    } catch (e) {
      state.status = 'Save failed: $e';
      state.notify();
      return false;
    }
  }

  Future<void> _newProject() async {
    if (_projectTransitionPending || _exitPending || state.interactionLocked) {
      return;
    }
    _projectTransitionPending = true;
    try {
      if (!await _confirmDiscard(before: 'starting a new project') ||
          !mounted) {
        return;
      }
      final revision = state.doc.revision;
      // Drain old autosaves before discarding their document. A failed cleanup
      // or an intervening edit keeps the current project available to the user.
      if (!await _clearRecovery(expectedRevision: revision, allowDirty: true)) {
        return;
      }
      if (!mounted ||
          state.doc.revision != revision ||
          state.interactionLocked) {
        return;
      }
      await state.newProject();
    } finally {
      _projectTransitionPending = false;
    }
  }

  Future<void> _openProject() async {
    if (_projectTransitionPending || _exitPending) return;
    _projectTransitionPending = true;
    try {
      if (!await _confirmDiscard() || !mounted) return;
      final file = await openFile(
        initialDirectory: _lastDirectory,
        acceptedTypeGroups: [
          const XTypeGroup(label: 'mmx project', extensions: ['mmx']),
        ],
      );
      if (file != null) {
        if (await state.openProject(file.path)) {
          await _clearRecovery();
          _lastDirectory = File(file.path).parent.path;
        }
      }
    } catch (e) {
      state.status = 'Open failed: $e';
      state.notify();
    } finally {
      _projectTransitionPending = false;
    }
  }

  Future<void> _transform() async {
    if (state.selected == null) return;
    final controllers = List.generate(
      7,
      (i) => TextEditingController(text: i == 6 ? '1' : '0'),
    );
    const labels = [
      'X (mm)',
      'Y (mm)',
      'Z (mm)',
      'Rotate X (degrees)',
      'Rotate Y (degrees)',
      'Rotate Z (degrees)',
      'Uniform scale',
    ];
    final values = await showDialog<List<double>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Transform selected'),
        content: SizedBox(
          width: 300,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 7; i++)
                  TextField(
                    controller: controllers[i],
                    decoration: InputDecoration(labelText: labels[i]),
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
              final v = controllers
                  .map((c) => double.tryParse(c.text))
                  .toList();
              if (v.any((n) => n == null || !n.isFinite) || v[6]! <= 0) return;
              Navigator.pop(context, v.cast<double>());
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    for (final c in controllers) {
      c.dispose();
    }
    if (values == null) return;
    Float64List m = scale4(values[6]);
    for (var i = 0; i < 3; i++) {
      m = multiply4(
        rotation4(
          i == 0 ? 1 : 0,
          i == 1 ? 1 : 0,
          i == 2 ? 1 : 0,
          values[i + 3] * 3.141592653589793 / 180,
        ),
        m,
      );
    }
    final pivot = state.selected?.pivot;
    if (pivot != null) {
      final local = pivot.position, t = state.selected!.transform;
      final p = [
        for (var i = 0; i < 3; i++)
          t[i] * local[0] +
              t[i + 4] * local[1] +
              t[i + 8] * local[2] +
              t[i + 12],
      ];
      m = multiply4(
        translation4(p[0], p[1], p[2]),
        multiply4(m, translation4(-p[0], -p[1], -p[2])),
      );
    }
    await state.transformSelected(
      multiply4(translation4(values[0], values[1], values[2]), m),
    );
  }

  Future<void> _boolean() async {
    final others = state.doc.objects
        .where((o) => o.id != state.selectedObjectId)
        .toList();
    if (state.selected == null || others.isEmpty) {
      state.status = 'Boolean needs two objects';
      state.notify();
      return;
    }
    var target = others.first.id;
    var op = BooleanOp.union;
    var precise = true;
    final apply = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Boolean selected with…'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButton<int>(
                value: target,
                items: others
                    .map(
                      (o) => DropdownMenuItem(value: o.id, child: Text(o.name)),
                    )
                    .toList(),
                onChanged: (v) => update(() => target = v!),
              ),
              DropdownButton<BooleanOp>(
                value: op,
                items: BooleanOp.values
                    .map((o) => DropdownMenuItem(value: o, child: Text(o.name)))
                    .toList(),
                onChanged: (v) => update(() => op = v!),
              ),
              CheckboxListTile(
                title: const Text('Precise (may fall back to grid)'),
                value: precise,
                onChanged: (v) => update(() => precise = v!),
              ),
              const Text(
                'Replaces the selected object; keeps the other operand.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (apply == true) await state.doBoolean(target, op, precise: precise);
  }
}

class _EmptyProject extends StatelessWidget {
  final VoidCallback onImport;
  final VoidCallback onOpen;
  const _EmptyProject({required this.onImport, required this.onOpen});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.create_new_folder_outlined, size: 32),
                const SizedBox(height: 12),
                Text(
                  'Empty project',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Import a mesh to begin, or open an existing .mmx project.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('empty-project-import'),
                      onPressed: onImport,
                      icon: const Icon(Icons.file_open_outlined),
                      label: const Text('Import mesh…'),
                    ),
                    TextButton(
                      key: const ValueKey('empty-project-open'),
                      onPressed: onOpen,
                      child: const Text('Open project…'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
