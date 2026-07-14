class ReplaceRule {
  final String id;
  final String name;
  final String pattern;
  final String replacement;
  final bool isRegex;
  final bool isEnabled;

  const ReplaceRule({
    required this.id,
    required this.name,
    required this.pattern,
    this.replacement = '',
    this.isRegex = false,
    this.isEnabled = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'pattern': pattern,
    'replacement': replacement,
    'isRegex': isRegex,
    'isEnabled': isEnabled,
  };

  factory ReplaceRule.fromJson(Map<String, dynamic> json) => ReplaceRule(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    pattern: json['pattern'] as String? ?? '',
    replacement: json['replacement'] as String? ?? '',
    isRegex: json['isRegex'] as bool? ?? false,
    isEnabled: json['isEnabled'] as bool? ?? true,
  );

  ReplaceRule copyWith({
    String? id,
    String? name,
    String? pattern,
    String? replacement,
    bool? isRegex,
    bool? isEnabled,
  }) => ReplaceRule(
    id: id ?? this.id,
    name: name ?? this.name,
    pattern: pattern ?? this.pattern,
    replacement: replacement ?? this.replacement,
    isRegex: isRegex ?? this.isRegex,
    isEnabled: isEnabled ?? this.isEnabled,
  );
}
