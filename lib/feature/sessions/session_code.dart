import 'dart:math';

import 'wordlist.dart';

const sessionCodeWordCount = 4;
const sessionCodeSeparator = '-';
final sessionCodePattern = RegExp(
  '^[a-z]+($sessionCodeSeparator[a-z]+){${sessionCodeWordCount - 1}}\$',
);

class SessionCodeGenerator {
  SessionCodeGenerator({this._words = effWords, Random? random})
    : _random = random ?? Random.secure();

  final List<String> _words;
  final Random _random;

  double get entropyBits => sessionCodeWordCount * log(_words.length) / ln2;

  String next() => List.generate(
    sessionCodeWordCount,
    (_) => _words[_random.nextInt(_words.length)],
  ).join(sessionCodeSeparator);
}

String? normalizeSessionCode(String input) {
  final code = input.trim().toLowerCase();
  return sessionCodePattern.hasMatch(code) ? code : null;
}
