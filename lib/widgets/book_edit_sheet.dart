import 'package:flutter/material.dart';
import '../../models/book.dart';
import '../../services/storage_service.dart';

class BookEditSheet extends StatefulWidget {
  final Book book;
  final VoidCallback onSaved;

  const BookEditSheet({
    super.key,
    required this.book,
    required this.onSaved,
  });

  @override
  State<BookEditSheet> createState() => _BookEditSheetState();
}

class _BookEditSheetState extends State<BookEditSheet> {
  late TextEditingController _nameController;
  late TextEditingController _authorController;
  late TextEditingController _coverUrlController;
  late TextEditingController _introController;
  late TextEditingController _publisherController;
  late TextEditingController _categoryController;
  late TextEditingController _tagsController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.book.customName ?? widget.book.name);
    _authorController = TextEditingController(text: widget.book.customAuthor ?? widget.book.author);
    _coverUrlController = TextEditingController(text: widget.book.customCoverUrl ?? widget.book.coverUrl);
    _introController = TextEditingController(text: widget.book.customIntro ?? widget.book.intro);
    _publisherController = TextEditingController(text: widget.book.publisher ?? '');
    _categoryController = TextEditingController(text: widget.book.category ?? '');
    _tagsController = TextEditingController(text: widget.book.tags?.join(', ') ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _authorController.dispose();
    _coverUrlController.dispose();
    _introController.dispose();
    _publisherController.dispose();
    _categoryController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.6,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Text('编辑书籍信息', style: Theme.of(context).textTheme.titleLarge),
                  const Spacer(),
                  TextButton(
                    onPressed: _save,
                    child: const Text('保存'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                children: [
                  _buildSectionTitle('基本信息'),
                  _buildTextField(_nameController, '书名', hint: '自定义书名，留空使用原始值'),
                  _buildTextField(_authorController, '作者', hint: '自定义作者，留空使用原始值'),
                  _buildTextField(_coverUrlController, '封面地址', hint: '封面图片URL或本地路径'),
                  _buildSectionTitle('简介'),
                  _buildTextField(
                    _introController,
                    '简介',
                    hint: '支持纯文本、Markdown、HTML格式',
                    maxLines: 5,
                  ),
                  _buildSectionTitle('扩展信息'),
                  _buildTextField(_publisherController, '出版社', hint: '如：人民文学出版社'),
                  _buildTextField(_categoryController, '分类', hint: '如：玄幻、科幻、文学'),
                  _buildTextField(_tagsController, '标签', hint: '多个标签用逗号分隔，如：修仙, 热血'),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: _resetToOriginal,
                    icon: const Icon(Icons.restore, size: 18),
                    label: const Text('恢复为原始信息'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
      child: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 14,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String label, {
    String? hint,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIcon: controller.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    controller.clear();
                    setState(() {});
                  },
                )
              : null,
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  void _save() {
    final name = _nameController.text.trim();
    final author = _authorController.text.trim();
    final coverUrl = _coverUrlController.text.trim();
    final intro = _introController.text.trim();
    final publisher = _publisherController.text.trim();
    final category = _categoryController.text.trim();
    final tagsText = _tagsController.text.trim();

    // 只有与原始值不同时才设置自定义值
    final customName = name != widget.book.name ? name : null;
    final customAuthor = author != widget.book.author ? author : null;
    final customCoverUrl = coverUrl != widget.book.coverUrl ? coverUrl : null;
    final customIntro = intro != widget.book.intro ? intro : null;

    List<String>? tags;
    if (tagsText.isNotEmpty) {
      tags = tagsText.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
      if (tags.isEmpty) tags = null;
    }

    final updatedBook = widget.book.copyWith(
      customName: customName,
      customAuthor: customAuthor,
      customCoverUrl: customCoverUrl,
      customIntro: customIntro,
      publisher: publisher.isNotEmpty ? publisher : null,
      category: category.isNotEmpty ? category : null,
      tags: tags ?? widget.book.tags,
    );

    StorageService.instance.saveBook(updatedBook);
    widget.onSaved();
    Navigator.pop(context);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('书籍信息已更新'), behavior: SnackBarBehavior.floating),
    );
  }

  void _resetToOriginal() {
    _nameController.text = widget.book.name;
    _authorController.text = widget.book.author;
    _coverUrlController.text = widget.book.coverUrl;
    _introController.text = widget.book.intro;
    _publisherController.clear();
    _categoryController.clear();
    _tagsController.clear();
    setState(() {});

    final updatedBook = widget.book.copyWith(
      customName: null,
      customAuthor: null,
      customCoverUrl: null,
      customIntro: null,
      publisher: null,
      category: null,
    );

    StorageService.instance.saveBook(updatedBook);
    widget.onSaved();
    Navigator.pop(context);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已恢复为原始信息'), behavior: SnackBarBehavior.floating),
    );
  }
}
