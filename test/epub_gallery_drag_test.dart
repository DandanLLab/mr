// 单框模型拖动提交测试：模拟横向拖动，验证 slide 提交与文字层切换
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mr/pages/reader/epub_gallery_page.dart';
import 'package:mr/services/local_book/epub_parser.dart';

// 1x1 白色 PNG
final png = Uint8List.fromList([
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1,
  0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84,
  120, 156, 99, 250, 207, 192, 80, 15, 0, 4, 133, 1, 128, 132, 163, 178,
  207, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
]);

EpubGalleryImage img(String title) => EpubGalleryImage(
      src: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      maintitle: title,
    );

void main() {
  testWidgets('横向拖动提交到下一张并切换文字层', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: EpubGalleryPage(
        images: [img('图一'), img('图二'), img('图三')],
        chapterTitle: '画廊图',
        backgroundColor: Colors.white,
        textColor: Colors.black,
        baseFontSize: 9,
        onPreviousChapter: () {},
        onNextChapter: () {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('图一'), findsOneWidget);

    // 从框内 (180,250) 向左拖 200 逻辑px（框 x18-342、y175-337）
    await tester.dragFrom(const Offset(180, 250), const Offset(-200, 0));
    await tester.pumpAndSettle();
    // 推过提交后 600ms 的 dump 延迟定时器
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.text('图二'), findsOneWidget);
    expect(find.text('图一'), findsNothing);
  });

  testWidgets('长描述自动缩字号不撞圆点行', (tester) async {
    final longSub = '很' * 90; // 90 字长描述
    await tester.pumpWidget(MaterialApp(
      home: EpubGalleryPage(
        images: [
          EpubGalleryImage(
            src: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
            maintitle: '长描述页',
            subtitle: longSub,
          ),
          img('图二'),
        ],
        chapterTitle: '画廊图',
        backgroundColor: Colors.white,
        textColor: Colors.black,
        baseFontSize: 15,
        onPreviousChapter: () {},
        onNextChapter: () {},
      ),
    ));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));

    // 不应有布局异常
    expect(tester.takeException(), isNull);
    // subtitle 存在且被缩字号渲染（找到文本）
    expect(find.text(longSub), findsOneWidget);
    // 文字必须完整显示：RenderBox 底部仍在页面内（圆点行会下移让位）
    final subBox = tester.renderObject<RenderBox>(find.text(longSub).last);
    final subBottom = subBox.localToGlobal(Offset.zero).dy + subBox.size.height;
    expect(subBottom, lessThanOrEqualTo(592));
    // 全文渲染（无省略号截断）：能按完整文本找到
    expect(find.text(longSub), findsOneWidget);
  });

  testWidgets('拖动幅度不足回弹不提交', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: EpubGalleryPage(
        images: [img('图一'), img('图二')],
        chapterTitle: '画廊图',
        backgroundColor: Colors.white,
        textColor: Colors.black,
        baseFontSize: 9,
        onPreviousChapter: () {},
        onNextChapter: () {},
      ),
    ));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(180, 250), const Offset(-40, 0));
    await tester.pumpAndSettle();
    expect(find.text('图一'), findsOneWidget);
  });
}
