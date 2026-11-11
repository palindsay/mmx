#!/usr/bin/env python3
"""Exercise real GTK dialogs and AT-SPI on an isolated Linux Studio instance.

Requires Xvfb, dbus-run-session, xdotool, Python GI/Atspi, and ImageMagick.
No app-state injection, native-dialog mocks, personal files, or active desktop.
The output is machine-driven evidence, not human accessibility certification.
"""
import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import sys
import tempfile
import time
import zipfile


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True, type=Path,
                        help='Directory containing mmx_studio, lib/, and data/')
    parser.add_argument('--xdotool', default='xdotool')
    parser.add_argument('--label', required=True, help='Build version/source description')
    parser.add_argument('--inside', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    args.bundle = args.bundle.resolve()
    if args.inside is None:
        root = Path(tempfile.mkdtemp(prefix='mmx-native-acceptance-'))
        for name in ('data', 'config', 'cache', 'runtime', 'files', 'evidence'):
            (root / name).mkdir(mode=0o700)
        env = dict(os.environ)
        for variable, name in (('XDG_DATA_HOME', 'data'), ('XDG_CONFIG_HOME', 'config'),
                               ('XDG_CACHE_HOME', 'cache'), ('XDG_RUNTIME_DIR', 'runtime')):
            env[variable] = str(root / name)
        env.update(GTK_MODULES='atk-bridge', GTK_USE_PORTAL='0', GIO_USE_VFS='local',
                   GIO_USE_VOLUME_MONITOR='unix', LANG='C.UTF-8')
        command = ['dbus-run-session', '--', 'xvfb-run', '-a', '-s',
                   '-screen 0 1280x800x24 -nolisten tcp', sys.executable,
                   str(Path(__file__).resolve()), '--bundle', str(args.bundle),
                   '--xdotool', args.xdotool, '--label', args.label, '--inside', str(root)]
        print(f'Evidence directory: {root}', flush=True)
        return subprocess.call(command, env=env)

    import gi
    gi.require_version('Atspi', '2.0')
    from gi.repository import Atspi, GLib

    root = args.inside
    if os.getuid() == 0:
        raise RuntimeError('Run as an ordinary user; root bypasses the permission test')
    evidence = root / 'evidence'
    results = {'label': args.label, 'started_utc': datetime.now(timezone.utc).isoformat(),
               'harness_sha256': digest(__file__), 'host': platform.platform(),
               'os_release': Path('/etc/os-release').read_text(), 'uid': os.getuid(),
               'display': os.environ['DISPLAY'], 'session': 'private D-Bus / Xvfb / XDG',
               'build_mode': 'release (caller-supplied binary)',
               'binaries': {str(p.relative_to(args.bundle)): digest(p) for p in
                            (args.bundle / 'mmx_studio', args.bundle / 'lib/libapp.so')},
               'checks': [], 'limitations': ['No human screen-reader acceptance',
               'No physical display, HiDPI, Wayland portal, or clean OS install coverage']}
    proc = None
    app_log = (evidence / 'application.log').open('ab')

    def pause(seconds=.15):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            while GLib.MainContext.default().pending():
                GLib.MainContext.default().iteration(False)
            time.sleep(.01)

    def walk():
        nodes = []
        def visit(node, depth=0):
            if node is None or depth > 25 or len(nodes) > 1000:
                return
            try:
                name = node.get_name()
                if name == 'Places':  # Do not record personal mounts or network places.
                    return
                nodes.append(node)
                for index in range(node.get_child_count()):
                    visit(node.get_child_at_index(index), depth + 1)
            except GLib.Error:
                pass
        visit(Atspi.get_desktop(0))
        return nodes

    def find(name=None, role=None, contains=None):
        matches = []
        for node in walk():
            try:
                if ((name is None or node.get_name() == name)
                        and (role is None or node.get_role_name() == role)
                        and (contains is None or contains in node.get_name())):
                    matches.append(node)
            except GLib.Error:
                # A native dialog can remove its D-Bus objects between reads.
                continue
        return matches

    def wait(predicate, detail, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            pause(.1)
        raise AssertionError(f'Timed out: {detail}')

    def xdo(*arguments):
        subprocess.run([args.xdotool, *map(str, arguments)], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        pause()

    def window():
        return subprocess.check_output([args.xdotool, 'search', '--onlyvisible',
                                        '--name', '^mmx_studio$'], text=True).splitlines()[0]

    def focus():
        xdo('windowfocus', '--sync', window())

    def key(keys):
        xdo('key', '--clearmodifiers', keys)

    def invoke(name, action=0, role=None):
        node = wait(lambda: find(name=name, role=role), name)[0]
        assert node.get_action_iface().do_action(action), f'Action failed: {name}'
        pause(.25)

    def record(name, **details):
        results['checks'].append({'name': name, 'result': 'pass', **details})
        (evidence / 'report.json').write_text(json.dumps(results, indent=2, ensure_ascii=False))
        print(json.dumps(results['checks'][-1], ensure_ascii=False), flush=True)

    def snapshot(name):
        nodes = []
        for node in walk():
            if node.get_name() or node.get_action_iface():
                action = node.get_action_iface()
                nodes.append({'name': node.get_name(), 'role': node.get_role_name(),
                              'description': node.get_description(),
                              'actions': [Atspi.Action.get_localized_name(node, i) for i in range(action.get_n_actions())]
                              if action else []})
        (evidence / f'{name}.json').write_text(json.dumps(nodes, indent=2, ensure_ascii=False))
        subprocess.run(['import', '-window', 'root', str(evidence / f'{name}.png')], check=True)

    def canvas_pixels(name, crop):
        # The isolated display is fixed at 1280x800 and Studio opens 1280x720.
        # Exclude toolbars, the live render-time HUD, and the sidebar so a
        # changed button or timing label cannot satisfy the visual check.
        raw = subprocess.check_output([
            'convert', str(evidence / f'{name}.png'), '-crop', crop,
            '+repage', '-depth', '8', 'RGB:-'])
        return list(zip(raw[0::3], raw[1::3], raw[2::3]))

    def start():
        nonlocal proc
        proc = subprocess.Popen([str(args.bundle / 'mmx_studio')], cwd=args.bundle,
                                stdout=app_log, stderr=subprocess.STDOUT)
        wait(lambda: find(name='mmx_studio', role='frame'), 'native window')
        pause(1)
        focus()

    def choose_open(path):
        wait(lambda: find(name='Open File', role='file chooser'), 'native Open File')
        key('ctrl+l')
        entry = wait(lambda: find(role='text'), 'GTK location entry')[0]
        assert Atspi.EditableText.set_text_contents(entry, str(path))
        key('Return')

    def choose_save(path):
        wait(lambda: find(name='Save File', role='file chooser'), 'native Save File')
        entry = find(role='text')[0]
        assert Atspi.EditableText.set_text_contents(entry, str(path))
        # GTK validates the edited destination asynchronously. An AT-SPI action
        # can report success while the Save widget is still insensitive.
        pause(.5)
        buttons = wait(lambda: [node for node in find(name='Save', role='button')
                                if node.get_state_set().contains(Atspi.StateType.SENSITIVE)],
                       'GTK Save becomes sensitive')
        assert buttons[-1].get_action_iface().do_action(0)
        wait(lambda: not find(name='Save File', role='file chooser'), 'native Save closes')

    def save_as(path):
        invoke('Project')
        invoke('Save project as…')
        choose_save(path)

    def objects(count):
        return bool(find(name=f'Objects\n{count}'))

    def dirty():
        return bool(find(contains='Unsaved changes'))

    def project(path):
        with zipfile.ZipFile(path) as archive:
            return json.loads(archive.read('manifest.json'))

    def close_request():
        # A real ICCCM WM_DELETE_WINDOW event. xdotool windowclose destroys the
        # X window directly and would bypass the application's dirty-exit path.
        class MessageData(ctypes.Union):
            _fields_ = [('b', ctypes.c_char * 20), ('s', ctypes.c_short * 10),
                        ('l', ctypes.c_long * 5)]
        class ClientMessage(ctypes.Structure):
            _fields_ = [('type', ctypes.c_int), ('serial', ctypes.c_ulong),
                        ('send_event', ctypes.c_int), ('display', ctypes.c_void_p),
                        ('window', ctypes.c_ulong), ('message_type', ctypes.c_ulong),
                        ('format', ctypes.c_int), ('data', MessageData)]
        class Event(ctypes.Union):
            _fields_ = [('client', ClientMessage), ('padding', ctypes.c_long * 24)]
        x11 = ctypes.CDLL('libX11.so.6')
        x11.XOpenDisplay.restype = ctypes.c_void_p
        x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        x11.XInternAtom.restype = ctypes.c_ulong
        x11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        x11.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int,
                                  ctypes.c_long, ctypes.POINTER(Event)]
        x11.XFlush.argtypes = [ctypes.c_void_p]
        x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        display = x11.XOpenDisplay(None)
        assert display
        event = Event()
        event.client.type, event.client.format = 33, 32
        event.client.display = display
        event.client.window = int(window())
        event.client.message_type = x11.XInternAtom(display, b'WM_PROTOCOLS', False)
        event.client.data.l[0] = x11.XInternAtom(display, b'WM_DELETE_WINDOW', False)
        assert x11.XSendEvent(display, event.client.window, False, 0, ctypes.byref(event))
        x11.XFlush(display)
        x11.XCloseDisplay(display)
        pause(.5)

    try:
        for prop in ('IsEnabled', 'ScreenReaderEnabled'):
            subprocess.run(['gdbus', 'call', '--session', '--dest', 'org.a11y.Bus',
                            '--object-path', '/org/a11y/bus', '--method',
                            'org.freedesktop.DBus.Properties.Set', 'org.a11y.Status',
                            prop, '<true>'], check=True, stdout=subprocess.PIPE)
        fixture = root / 'files/模型-1in.obj'
        fixture.write_text('v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n')
        saved = root / 'files/项目.mmx'
        start()
        wait(lambda: objects(1), 'procedural startup')
        labels = ['Project', 'Import mesh', 'Export selected', 'Navigate', 'Select',
                  'Sculpt', 'Stamp', 'Plane Cut', 'Mirror', 'Extrude', 'Separate Shells',
                  'Remesh', 'Reduce', 'Make Solid', 'Hollow', 'Analysis', 'Supports',
                  'Modify', 'Print / Layout', 'Wireframe', 'Print bed', 'Frame selection']
        for label in labels:
            assert find(name=label), f'No accessible name: {label}'
        snapshot('01-accessible-startup')
        record('AT-SPI icon/tool control names', labels=labels)
        invoke('Print bed')
        pause(.5)
        snapshot('01b-print-bed-off')
        crop = '850x510+80+140'
        before = canvas_pixels('01-accessible-startup', crop)
        after = canvas_pixels('01b-print-bed-off', crop)
        changed = sum(a != b for a, b in zip(before, after))
        assert changed > 100, 'Print bed toggle did not change the viewport grid/outline'
        # This region is inside the lower half of the deterministic startup
        # sphere, below y=0. An opaque floor would replace these blue surface
        # pixels when enabled, even though the AT-SPI toggle state is correct.
        lower_crop = '80x40+460+470'
        lower_before = canvas_pixels('01-accessible-startup', lower_crop)
        lower_after = canvas_pixels('01b-print-bed-off', lower_crop)
        surface = [i for i, (r, g, b) in enumerate(lower_after)
                   if g > r + 10 and b > r + 15]
        assert len(surface) > 2000, 'Expected below-bed sphere surface is not visible'
        retained = sum(lower_before[i] == lower_after[i] for i in surface)
        assert retained >= len(surface) * .90, 'Enabled bed hides below-bed sphere surface'
        invoke('Print bed')
        pause(.5)
        snapshot('01c-print-bed-restored')
        restored = canvas_pixels('01c-print-bed-restored', crop)
        assert restored == before, 'Restoring Print bed did not restore the viewport'
        assert not dirty()
        record('Print bed visually toggles grid/outline and preserves below-bed geometry',
               canvas_crop=crop, changed_pixels=changed, below_bed_crop=lower_crop,
               visible_surface_pixels=len(surface), retained_surface_pixels=retained)
        invoke('Sculpt')
        wait(lambda: find(name='Size', role='slider'), 'named brush slider')
        invoke('Navigate')
        record('AT-SPI tool activation and named slider')
        focus()
        key('ctrl+o')
        wait(lambda: find(name='Open File'), 'import dialog')
        key('Escape')
        wait(lambda: not find(name='Open File'), 'import canceled')
        assert objects(1) and not dirty()
        record('native Import cancel leaves document unchanged')
        focus()
        key('ctrl+o')
        choose_open(fixture)
        wait(lambda: find(name='Units used by this mesh'), 'unit choice')
        invoke('Inches', action=1)
        key('Return')
        wait(lambda: objects(2), 'mesh imported')
        assert dirty()
        record('Unicode native open and keyboard Inches selection')
        focus()
        key('ctrl+s')
        wait(lambda: find(name='Save File'), 'save dialog')
        key('Escape')
        wait(lambda: not find(name='Save File'), 'save canceled')
        assert dirty() and not saved.exists()
        focus()
        key('ctrl+s')
        choose_save(saved)
        wait(lambda: saved.exists() and not dirty(), 'save completed')
        with zipfile.ZipFile(saved) as archive:
            manifest = json.loads(archive.read('manifest.json'))
            mesh = next(o for o in manifest['objects'] if o['name'] == fixture.name)
            raw = archive.read(mesh['positions'])
            positions = struct.unpack('<' + 'f' * (len(raw) // 4), raw)
            assert abs(max(positions) - 25.4) < 1e-5
        record('native Save cancel, Unicode save, units persisted',
               units=manifest['units'], positions=list(positions), sha256=digest(saved))
        focus()
        key('ctrl+z')
        wait(lambda: objects(1), 'keyboard Undo')
        key('ctrl+shift+z')
        wait(lambda: objects(2), 'keyboard Redo')
        key('ctrl+z')
        wait(lambda: objects(1), 'second Undo')
        record('keyboard Undo and Redo')
        original = digest(saved)
        save_as(saved)
        wait(lambda: find(name='Replace existing file?'), 'overwrite confirmation')
        invoke('Cancel')
        assert digest(saved) == original and dirty()
        save_as(saved)
        invoke('Replace')
        wait(lambda: not dirty(), 'replace complete')
        assert digest(saved) != original and len(project(saved)['objects']) == 1
        record('Save As overwrite Cancel preserves bytes; Replace changes file',
               before_sha256=original, after_sha256=digest(saved))
        invoke('Export selected')
        exported = root / 'files/exported.stl'
        choose_save(exported)
        wait(exported.exists, 'native STL export')
        triangle_count = struct.unpack('<I', exported.read_bytes()[80:84])[0]
        assert triangle_count == 960 and exported.stat().st_size == 84 + 50 * triangle_count
        invoke('Export selected')
        choose_save(exported)
        invoke('Cancel')
        record('native STL export and overwrite Cancel', triangles=triangle_count,
               sha256=digest(exported))
        focus()
        key('ctrl+shift+z')
        wait(lambda: objects(2) and dirty(), 'dirty state for failure tests')
        denied = root / 'files/readonly'
        denied.mkdir(mode=0o555)
        try:
            save_as(denied / 'denied.mmx')
            wait(lambda: find(contains='Save project failed') or find(contains='Save failed'),
                 'permission error reported')
            assert dirty() and not (denied / 'denied.mmx').exists()
            snapshot('02-permission-failure')
            record('native destination permission failure preserves dirty document')
        finally:
            denied.chmod(0o700)
        close_request()
        wait(lambda: find(name='Save changes?'), 'dirty-exit prompt')
        invoke('Cancel')
        assert proc.poll() is None and dirty()
        record('WM_DELETE_WINDOW dirty-exit Cancel retains app/document')
        # Wait across the real 30-second recovery timer, then kill the actual app.
        recovery = wait(lambda: list((root / 'data').rglob('recovery-*.mmx')),
                        'periodic autosave', timeout=40)[0]
        wait(lambda: len(project(recovery)['objects']) == 2, 'latest recovery')
        recovery_hash = digest(recovery)
        proc.kill()
        proc.wait(timeout=10)
        start()
        wait(lambda: find(name='Recover unsaved project?'), 'recovery prompt')
        invoke('Keep for later')
        assert recovery.exists() and digest(recovery) == recovery_hash
        close_request()
        wait(lambda: proc.poll() is not None, 'clean close')
        start()
        invoke('Recover')
        wait(lambda: objects(2) and dirty(), 'recovered scene')
        record('forced termination, Keep for later, then Recover',
               recovery_sha256=recovery_hash)
        recovered = root / 'files/recovered.mmx'
        close_request()
        invoke('Save')
        wait(lambda: find(name='Save File'), 'dirty-exit Save dialog')
        key('Escape')
        wait(lambda: not find(name='Save File'), 'exit Save canceled')
        assert proc.poll() is None and dirty()
        close_request()
        invoke('Save')
        choose_save(recovered)
        wait(lambda: proc.poll() is not None, 'dirty-exit Save completed')
        assert recovered.exists() and len(project(recovered)['objects']) == 2
        record('dirty-exit Save dialog Cancel keeps app; successful Save exits')
        start()
        assert not find(name='Recover unsaved project?')
        invoke('Project')
        invoke('Open project…')
        choose_open(recovered)
        wait(lambda: objects(2) and not dirty(), 'saved recovery reopened')
        invoke('Project')
        invoke('Open project…')
        choose_open(saved)
        wait(lambda: objects(1) and not dirty(), 'native project reopened')
        record('recovered project requires chosen save path; native project reopen',
               recovered_sha256=digest(recovered))
        focus()
        key('ctrl+o')
        choose_open(fixture)
        invoke('Millimeters')
        wait(lambda: objects(2) and dirty(), 'dirty before discard exit')
        close_request()
        invoke('Discard')
        wait(lambda: proc.poll() is not None, 'discard exit')
        record('WM_DELETE_WINDOW dirty-exit Discard exits')
        results['result'] = 'pass'
        results['completed_utc'] = datetime.now(timezone.utc).isoformat()
    except Exception as error:
        results['result'] = 'fail'
        results['error'] = repr(error)
        try:
            snapshot('failure')
        except Exception:
            pass
        raise
    finally:
        if proc is not None and proc.poll() is None:
            proc.kill()
            proc.wait(timeout=10)
        app_log.close()
        (evidence / 'report.json').write_text(json.dumps(results, indent=2, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
