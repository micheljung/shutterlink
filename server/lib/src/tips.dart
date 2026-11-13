class Tip {
  Tip(this.label, this.url) {
    if (label.trim().isEmpty) {
      throw const FormatException('Tip label must not be empty');
    }
    if (!const {'http', 'https'}.contains(url.scheme) || url.host.isEmpty) {
      throw FormatException('Tip URL must be http or https', url.toString());
    }
  }

  factory Tip.parse(String spec) {
    final separator = spec.indexOf('=');
    if (separator <= 0) {
      throw FormatException('Expected "Label=URL"', spec);
    }
    final url = Uri.tryParse(spec.substring(separator + 1).trim());
    if (url == null) throw FormatException('Invalid tip URL', spec);
    return Tip(spec.substring(0, separator).trim(), url);
  }

  final String label;
  final Uri url;
}
