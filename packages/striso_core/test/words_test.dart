// Stcw, the parameters' words: the command, the reply's lines, their place on the parameters.
import 'package:striso_core/striso_core.dart';
import 'package:test/test.dart';

void main() {
  test('Stcw is "Stcw"', () => expect(String.fromCharCodes(Cmd.words()), 'Stcw'));

  test('the header and a line: index, icon, label|hover; "-" for none', () {
    expect(parseWordsHeader('words 0 modal:wine glass 21'), (target: 0, name: 'modal:wine glass', count: 21));
    final w = parseWordsLine('3 release+pedal Release with the pedal|How long it rings: 0 off | 1 on. Range 0 to 3.\r')!;
    expect([w.index, w.icon, w.label, w.hover], [3, 'release+pedal', 'Release with the pedal', 'How long it rings: 0 off | 1 on. Range 0 to 3.']);
    final none = parseWordsLine('7 - |')!;
    expect([none.index, none.icon, none.label, none.hover], [7, '', '', '']);
    expect(parseWordsLine('params 0 va 3'), isNull);
  });

  test('the words go onto the parameters by index; another length leaves them', () {
    Param p(int i) => Param(index: i, name: 'p$i', group: 'g', min: 0, max: 1, value: 0, kind: 0);
    final ps = [p(0), p(1)];
    applyWords(ps, const [ParamWords(0, 'level', 'Level', 'How loud.'), ParamWords(1, '', '', '')]);
    expect([ps[0].icon, ps[0].label, ps[0].hover, ps[1].icon], ['level', 'Level', 'How loud.', '']);
    expect(ps[0].copy().label, 'Level');
    applyWords(ps, const [ParamWords(0, 'x', 'X', 'Y')]);
    expect(ps[0].icon, 'level');
  });
}
