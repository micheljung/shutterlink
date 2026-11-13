import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/sessions/session_code.dart';
import 'package:shutterlink/feature/sessions/wordlist.dart';

void main() {
  const minimumEntropyBits = 44;
  const sampleSize = 1000;

  test('the wordlist is lowercase letters only and unique', () {
    final word = RegExp(r'^[a-z]+$');

    expect(effWords.every(word.hasMatch), isTrue);
    expect(effWords.toSet(), hasLength(effWords.length));
  });

  test('four words carry at least 44 bits of entropy', () {
    final generator = SessionCodeGenerator();

    expect(
      sessionCodeWordCount * log(effWords.length) / ln2,
      greaterThanOrEqualTo(minimumEntropyBits),
    );
    expect(generator.entropyBits, greaterThanOrEqualTo(minimumEntropyBits));
  });

  test('the default generator yields valid, distinct codes', () {
    final generator = SessionCodeGenerator();
    final codes = {for (var i = 0; i < sampleSize; i++) generator.next()};

    expect(codes, hasLength(sampleSize));
    for (final code in codes) {
      expect(normalizeSessionCode(code), code);
      expect(code.split(sessionCodeSeparator), everyElement(isIn(effWords)));
    }
  });

  test('draws words from the injected random source', () {
    final generator = SessionCodeGenerator(
      words: const ['alpha', 'bravo', 'charlie'],
      random: Random(1),
    );
    final again = SessionCodeGenerator(
      words: const ['alpha', 'bravo', 'charlie'],
      random: Random(1),
    );

    expect(generator.next(), again.next());
  });

  test('normalizes case and whitespace and rejects malformed codes', () {
    expect(
      normalizeSessionCode('  Apple-Bread-Cider-Dough \n'),
      'apple-bread-cider-dough',
    );
    for (final invalid in [
      '',
      'apple-bread-cider',
      'apple-bread-cider-dough-extra',
      'apple--cider-dough',
      'apple-bread-cider-d0ugh',
      'apple bread cider dough',
      '../bread-cider-dough',
      'äpple-bread-cider-dough',
    ]) {
      expect(normalizeSessionCode(invalid), isNull, reason: invalid);
    }
  });
}
