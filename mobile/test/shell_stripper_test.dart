import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/services/chat_api.dart';

void main() {
  test('普通文本跨分片不丢字', () {
    final s = ShellTagStripper();
    final chunks = [
      '今天天气不错，',
      '我们出去走走[',
      '吧？'
          '对了你吃过饭',
      '了吗',
    ];
    final out = chunks.map(s.process).join();
    expect(out, '今天天气不错，我们出去走走[吧？对了你吃过饭了吗');
  });

  test('正常句子里的 shell 字样不误伤', () {
    final s = ShellTagStripper();
    expect(
      s.process('我说 shell 脚本，或者 powershell 都行'),
      '我说 shell 脚本，或者 powershell 都行',
    );
    expect(s.process('用 shellScript 写也行'), '用 shellScript 写也行');
  });

  test('[shell] 标记整段剥掉', () {
    final s = ShellTagStripper();
    expect(s.process('前面 [shell]free -h[/shell] 后面'), '前面  后面');
  });

  test('[shell: 变体剥掉', () {
    final s = ShellTagStripper();
    expect(s.process('查一下 [shell: uptime] 结果'), '查一下  结果');
  });
}
