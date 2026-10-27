// The parameters' icons: generated from awva's assets/icons at the pinned commit (tool/AWVA_COMMIT,
// tool/gen_param_icons.dart), every concept the engines name drawn.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:striso_live/src/ui/param_icon.dart';
import 'package:striso_live/src/ui/param_icons.g.dart';

void main() {
  test('lib/src/ui/param_icons.g.dart is from the pinned awva (dart run tool/gen_param_icons.dart)', () {
    expect(paramIconsCommit, File('tool/AWVA_COMMIT').readAsLinesSync().first.trim());
  });
  test('the concepts and modifiers are there; an icon is its concept, a modifier optional', () {
    expect(paramIconShapes.length, 111);
    expect(hasParamIcon('release'), isTrue);
    expect(hasParamIcon('release+pedal'), isTrue);
    expect(paramIconShapes.containsKey('mod-pedal'), isTrue);
    expect(hasParamIcon(''), isFalse);
    expect(hasParamIcon('nosuchconcept'), isFalse);
  });
}
