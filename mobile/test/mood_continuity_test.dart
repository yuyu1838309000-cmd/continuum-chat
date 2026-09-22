import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/mood.dart';

MoodEntry mood(
  int id, {
  int valence = 0,
  Map<String, double> dims = const {},
}) => MoodEntry(
  id: id,
  valence: valence,
  label: '测试',
  emoji: '',
  note: '',
  source: '',
  sourceType: '',
  createdAt: '',
  dims: dims,
);

void main() {
  test('sparse mood events inherit unchanged dimensions', () {
    final base = mood(
      10,
      valence: 7,
      dims: {
        'valence': 7,
        'arousal': 4,
        'longing': 6,
        'security': 8,
        'attachment': 9,
      },
    );
    final drift = mood(11, valence: 4);
    final memory = mood(12, valence: 5, dims: {'valence': 5, 'arousal': 6});

    final afterDrift = resolveMoodDimensions(drift, [base, drift, memory]);
    expect(afterDrift['valence'], 4);
    expect(afterDrift['arousal'], 4);
    expect(afterDrift['longing'], 6);
    expect(afterDrift['security'], 8);
    expect(afterDrift['attachment'], 9);

    final afterMemory = resolveMoodDimensions(memory, [base, drift, memory]);
    expect(afterMemory['valence'], 5);
    expect(afterMemory['arousal'], 6);
    expect(afterMemory['longing'], 6);
    expect(afterMemory['security'], 8);
  });

  test('older snapshot never sees later dimension changes', () {
    final base = mood(
      20,
      valence: 2,
      dims: {'valence': 2, 'desire': 3, 'guilt': 1},
    );
    final later = mood(
      21,
      valence: 6,
      dims: {'valence': 6, 'desire': 8, 'guilt': 0},
    );

    final resolved = resolveMoodDimensions(base, [base, later]);
    expect(resolved['valence'], 2);
    expect(resolved['desire'], 3);
    expect(resolved['guilt'], 1);
  });
}
