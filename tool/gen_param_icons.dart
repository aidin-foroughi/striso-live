// The parameters' icons (awva's assets/icons/*.svg) as shapes for the parameter rows and knobs:
// lib/src/ui/param_icons.g.dart, from awva at the commit pinned in tool/AWVA_COMMIT (the awva the
// firmware is built on). The SVGs are read from that commit (git), never copied here.
//   dart run tool/gen_param_icons.dart [AWVA_CHECKOUT]
// With AWVA_CHECKOUT (a local awva clone that has the pinned commit) it reads from there, else it
// fetches the commit from GitHub into a temporary directory. test/param_icons_test.dart checks the
// generated file names the pinned commit.
//
// Each icon is a list of shapes on its 24 x 24 grid, drawn with round caps and joins at a line of
// 1.5 grid units (the SVGs' own): 0 n x0 y0 .. a polyline (curves and arcs flattened, a dashed one
// as its dashes), 1 cx cy r a circle, 2 cx cy r a disc. An icon "concept+modifier" is the concept,
// a disc of the background at (19, 19) r 5.5, then "mod-<modifier>" (awva docs/icons.md). The
// flattening is awva-plugins' (app/tool/gen_icons.dart), so the shapes are the same as the awva
// app's and plugins'.
import 'dart:io';
import 'dart:math' as math;

const dartOut = 'lib/src/ui/param_icons.g.dart';
const pinFile = 'tool/AWVA_COMMIT';

String pinnedCommit() => File(pinFile).readAsLinesSync().first.trim();

/// the pinned commit's assets/icons, extracted into a temporary directory
String fetchIcons(String commit, String? checkout) {
  final tmp = Directory.systemTemp.createTempSync('awva-icons-');
  var repo = checkout;
  if (repo == null) {
    repo = '${tmp.path}/awva';
    for (final a in [
      ['init', '-q', repo],
      ['-C', repo, 'fetch', '-q', '--depth', '1', 'https://github.com/sorbet-ai/awva.git', commit],
    ]) {
      final r = Process.runSync('git', a);
      if (r.exitCode != 0) throw StateError('git ${a.join(' ')}: ${r.stderr}');
    }
  }
  final out = Directory('${tmp.path}/icons')..createSync();
  final ls = Process.runSync('git', ['-C', repo, 'ls-tree', '--name-only', '$commit:assets/icons']);
  if (ls.exitCode != 0) throw StateError('awva $commit has no assets/icons: ${ls.stderr}');
  for (final f in (ls.stdout as String).split('\n').map((s) => s.trim()).where((s) => s.endsWith('.svg'))) {
    final r = Process.runSync('git', ['-C', repo, 'show', '$commit:assets/icons/$f'], stdoutEncoding: const SystemEncoding());
    File('${out.path}/$f').writeAsStringSync(r.stdout as String);
  }
  return out.path;
}

Map<String, List<double>> readIcons(String dir) {
  final d = Directory(dir);
  if (!d.existsSync()) throw StateError("${d.path}: no icons");
  final files = d.listSync().whereType<File>().where((f) => f.path.endsWith('.svg')).toList()..sort((a, b) => a.path.compareTo(b.path));
  final out = <String, List<double>>{};
  for (final f in files) {
    final name = f.uri.pathSegments.last.replaceAll('.svg', '');
    out[name] = shapesOf(f.readAsStringSync().replaceAll('\r\n', '\n'), name);
  }
  return out;
}

Map<String, String> _attrs(String tag) => {for (final m in RegExp(r'([a-z-]+)="([^"]*)"').allMatches(tag)) m[1]!: m[2]!};

double _n(Map<String, String> a, String k) => double.parse(a[k] ?? '0');

/// one SVG's shapes
List<double> shapesOf(String svg, String name) {
  final out = <double>[];
  void poly(List<List<double>> pts) {
    if (pts.length < 2) return;
    out
      ..add(0)
      ..add(pts.length.toDouble());
    for (final p in pts) {
      out.addAll([_round(p[0]), _round(p[1])]);
    }
  }

  for (final m in RegExp(r'<(path|circle|rect)\b([^>]*)/?>').allMatches(svg)) {
    final a = _attrs(m[2]!);
    final filled = a['fill'] != null && a['fill'] != 'none';
    final stroked = a['stroke'] != 'none';
    List<List<List<double>>> lines;
    if (m[1] == 'circle') {
      final cx = _n(a, 'cx'), cy = _n(a, 'cy'), r = _n(a, 'r');
      if (filled) out.addAll([2, cx, cy, r]);
      if (stroked) out.addAll([1, cx, cy, r]);
      continue;
    } else if (m[1] == 'rect') {
      final x = _n(a, 'x'), y = _n(a, 'y'), w = _n(a, 'width'), h = _n(a, 'height');
      final rx = math.min(_n(a, 'rx'), math.min(w, h) / 2);
      lines = _path(
        'M${x + rx} ${y}H${x + w - rx}A$rx $rx 0 0 1 ${x + w} ${y + rx}V${y + h - rx}A$rx $rx 0 0 1 ${x + w - rx} ${y + h}'
        'H${x + rx}A$rx $rx 0 0 1 $x ${y + h - rx}V${y + rx}A$rx $rx 0 0 1 ${x + rx} ${y}Z',
        name,
      );
    } else {
      lines = _path(a['d'] ?? '', name);
    }
    if (filled) throw StateError('$name: a filled ${m[1]} (only discs are filled)');
    final dash = a['stroke-dasharray'];
    for (final l in lines) {
      if (dash == null) {
        poly(l);
      } else {
        for (final d in _dashed(l, [for (final s in dash.split(RegExp(r'[ ,]+'))) double.parse(s)])) {
          poly(d);
        }
      }
    }
  }
  if (out.isEmpty) throw StateError('$name: nothing drawn');
  return out;
}

double _round(double v) => (v * 1000).roundToDouble() / 1000;

/// the subpaths of a path's d, flattened to points
List<List<List<double>>> _path(String d, String name) {
  final tokens = RegExp(r'[A-Za-z]|-?(?:\d+\.?\d*|\.\d+)(?:e-?\d+)?').allMatches(d).map((m) => m[0]!).toList();
  final subs = <List<List<double>>>[];
  var cur = <List<double>>[];
  double x = 0, y = 0, sx = 0, sy = 0, cx2 = 0, cy2 = 0; // the point, the subpath's start, the last cubic's second control
  var i = 0;
  String cmd = '';
  String last = '';
  bool isNum(int k) => k < tokens.length && !RegExp(r'^[A-Za-z]$').hasMatch(tokens[k]);
  double num_() => double.parse(tokens[i++]);
  void cubic(double x1, double y1, double x2, double y2, double x3, double y3) {
    const n = 16;
    for (var k = 1; k <= n; k++) {
      final t = k / n, u = 1 - t;
      cur.add([
        u * u * u * x + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3,
        u * u * u * y + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3,
      ]);
    }
    cx2 = x2;
    cy2 = y2;
    x = x3;
    y = y3;
  }

  void arc(double rx, double ry, double rot, bool large, bool sweep, double x2, double y2) {
    // the endpoint parameterization to the centre one (SVG 1.1 F.6.5)
    if (rx == 0 || ry == 0) {
      cur.add([x2, y2]);
      x = x2;
      y = y2;
      return;
    }
    rx = rx.abs();
    ry = ry.abs();
    final phi = rot * math.pi / 180, cp = math.cos(phi), sp = math.sin(phi);
    final dx = (x - x2) / 2, dy = (y - y2) / 2;
    final x1p = cp * dx + sp * dy, y1p = -sp * dx + cp * dy;
    final lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lam > 1) {
      rx *= math.sqrt(lam);
      ry *= math.sqrt(lam);
    }
    final num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    final den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    var co = math.sqrt(math.max(0, num / den));
    if (large == sweep) co = -co;
    final cxp = co * rx * y1p / ry, cyp = -co * ry * x1p / rx;
    final ccx = cp * cxp - sp * cyp + (x + x2) / 2, ccy = sp * cxp + cp * cyp + (y + y2) / 2;
    double ang(double ux, double uy, double vx, double vy) {
      final a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
      return a;
    }

    final t1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    var dt = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
    if (!sweep && dt > 0) dt -= 2 * math.pi;
    if (sweep && dt < 0) dt += 2 * math.pi;
    final n = math.max(4, (dt.abs() / (math.pi / 16)).ceil());
    for (var k = 1; k <= n; k++) {
      final t = t1 + dt * k / n;
      if (k == n) {
        cur.add([x2, y2]);
      } else {
        cur.add([ccx + rx * math.cos(t) * cp - ry * math.sin(t) * sp, ccy + rx * math.cos(t) * sp + ry * math.sin(t) * cp]);
      }
    }
    x = x2;
    y = y2;
  }

  while (i < tokens.length) {
    if (!isNum(i)) {
      cmd = tokens[i++];
    } else if (cmd == 'M') {
      cmd = 'L';
    } else if (cmd == 'm') {
      cmd = 'l';
    }
    final rel = cmd == cmd.toLowerCase();
    final ox = rel ? x : 0.0, oy = rel ? y : 0.0;
    switch (cmd.toUpperCase()) {
      case 'M':
        if (cur.length > 1) subs.add(cur);
        x = ox + num_();
        y = oy + num_();
        sx = x;
        sy = y;
        cur = [
          [x, y],
        ];
      case 'L':
        x = ox + num_();
        y = oy + num_();
        cur.add([x, y]);
      case 'H':
        x = ox + num_();
        cur.add([x, y]);
      case 'V':
        y = oy + num_();
        cur.add([x, y]);
      case 'C':
        final x1 = ox + num_(), y1 = oy + num_(), x2 = ox + num_(), y2 = oy + num_(), x3 = ox + num_(), y3 = oy + num_();
        cubic(x1, y1, x2, y2, x3, y3);
      case 'S':
        final reflect = last.toUpperCase() == 'C' || last.toUpperCase() == 'S';
        final x1 = reflect ? 2 * x - cx2 : x, y1 = reflect ? 2 * y - cy2 : y;
        final x2 = ox + num_(), y2 = oy + num_(), x3 = ox + num_(), y3 = oy + num_();
        cubic(x1, y1, x2, y2, x3, y3);
      case 'A':
        final rx = num_(), ry = num_(), rot = num_(), large = num_() != 0, sweep = num_() != 0;
        final x2 = ox + num_(), y2 = oy + num_();
        arc(rx, ry, rot, large, sweep, x2, y2);
      case 'Z':
        cur.add([sx, sy]);
        x = sx;
        y = sy;
        if (cur.length > 1) subs.add(cur);
        cur = [
          [x, y],
        ];
      default:
        throw StateError('$name: path command $cmd');
    }
    last = cmd;
  }
  if (cur.length > 1) subs.add(cur);
  return subs;
}

/// a polyline as its dashes (pattern: on, off, on, off, ...)
List<List<List<double>>> _dashed(List<List<double>> l, List<double> pattern) {
  final out = <List<List<double>>>[];
  var k = 0;
  var left = pattern[0];
  var on = true;
  var dash = <List<double>>[l.first];
  for (var i = 1; i < l.length; i++) {
    var ax = l[i - 1][0], ay = l[i - 1][1];
    final bx = l[i][0], by = l[i][1];
    var seg = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
    while (seg > 1e-9) {
      final step = math.min(seg, left);
      final t = step / seg;
      ax += (bx - ax) * t;
      ay += (by - ay) * t;
      seg -= step;
      left -= step;
      if (on) dash.add([ax, ay]);
      if (left <= 1e-9) {
        if (on && dash.length > 1) out.add(dash);
        on = !on;
        k = (k + 1) % pattern.length;
        left = pattern[k];
        dash = [
          [ax, ay],
        ];
      }
    }
  }
  if (on && dash.length > 1) out.add(dash);
  return out;
}

String _num(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

String dartIcons(Map<String, List<double>> icons, String commit) {
  final b = StringBuffer()
    ..writeln('// GENERATED by tool/gen_param_icons.dart from awva $commit assets/icons/*.svg: do not edit.')
    ..writeln('// ignore_for_file: lines_longer_than_80_chars')
    ..writeln()
    ..writeln("/// the awva commit these icons are from (tool/AWVA_COMMIT)")
    ..writeln("const paramIconsCommit = '$commit';")
    ..writeln()
    ..writeln('/// icon name -> its shapes on the 24 grid: 0 n points.. a polyline, 1 cx cy r a circle, 2 cx cy r a disc')
    ..writeln('const paramIconShapes = <String, List<double>>{');
  for (final e in icons.entries) {
    b.writeln("  '${e.key}': [${e.value.map(_num).join(', ')}],");
  }
  b.writeln('};');
  return b.toString();
}

void main(List<String> args) {
  final commit = pinnedCommit();
  final icons = readIcons(fetchIcons(commit, args.isNotEmpty ? args.first : null));
  File(dartOut).writeAsStringSync(dartIcons(icons, commit));
  stdout.writeln('wrote $dartOut (${icons.length} icons, awva $commit)');
}
