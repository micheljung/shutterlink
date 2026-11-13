import 'package:equatable/equatable.dart';

import 'photo_group.dart';

class DaySection extends Equatable {
  const DaySection({required this.day, required this.groups});

  final DateTime? day;
  final List<PhotoGroup> groups;

  @override
  List<Object?> get props => [day, groups];
}

List<DaySection> sectionsOf(List<PhotoGroup> groups) {
  final sections = <DaySection>[];
  for (final group in groups) {
    final day = dayOf(group.captureDate);
    if (sections.isEmpty || sections.last.day != day) {
      sections.add(DaySection(day: day, groups: [group]));
    } else {
      sections.last.groups.add(group);
    }
  }
  return sections;
}

DateTime? dayOf(DateTime? date) {
  if (date == null) return null;
  final local = date.toLocal();
  return DateTime(local.year, local.month, local.day);
}
