// lib/screens/contacts_screen.dart
// 緊急連絡人管理（視障友善版）
// • 每位連絡人是全寬大色塊，點擊撥打電話
// • 長按大色塊進入編輯/刪除
// • 最底部是大型「新增連絡人」按鈕
// • 進入時語音播報操作說明

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import 'contact_form_screen.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  @override
  void initState() {
    super.initState();
    context.read<AppProvider>().loadContacts();
    // 進入時語音說明操作方式
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = context.read<AppProvider>();
      final contacts = app.contacts;
      if (contacts.isEmpty) {
        app.speak('緊急連絡人頁面，目前沒有連絡人。請點擊下方新增連絡人按鈕新增。');
      } else {
        app.speak(
          '緊急連絡人頁面，共${contacts.length}位。'
          '點擊連絡人可直接撥電話，長按可以編輯或刪除。',
        );
      }
    });
  }

  // 長按彈出編輯/刪除選單
  Future<void> _showOptions(
      BuildContext context, Map<String, dynamic> contact) async {
    final app = context.read<AppProvider>();
    HapticFeedback.mediumImpact();
    app.speak('已選取 ${contact['name']}，請選擇要執行的動作');

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖曳把手
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 聯絡人名稱標題
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text(
                contact['name'] as String,
                style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
            ),
            const Divider(color: Colors.white12),
            // 撥打電話
            _BottomSheetBtn(
              icon:  Icons.phone,
              label: '撥打電話',
              color: Colors.greenAccent,
              onTap: () => Navigator.pop(context, 'call'),
            ),
            // 編輯
            _BottomSheetBtn(
              icon:  Icons.edit,
              label: '編輯聯絡人',
              color: Colors.white70,
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            // 刪除
            _BottomSheetBtn(
              icon:  Icons.delete,
              label: '刪除聯絡人',
              color: Colors.redAccent,
              onTap: () => Navigator.pop(context, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (!mounted) return;
    switch (action) {
      case 'call':
        app.callContact(
          contact['name']  as String,
          contact['phone'] as String,
        );
      case 'edit':
        if (!context.mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ContactFormScreen(
              slot:     0,
              existing: contact,
            ),
          ),
        );
      case 'delete':
        if (!context.mounted) return;
        await _confirmDelete(context, contact);
    }
  }

  Future<void> _confirmDelete(
      BuildContext context, Map<String, dynamic> contact) async {
    final app = context.read<AppProvider>();
    app.speak('確定要刪除 ${contact['name']} 嗎？');

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text('刪除「${contact['name']}」？',
            style: const TextStyle(fontSize: 22)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(fontSize: 18)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade700),
            child: const Text('刪除', style: TextStyle(fontSize: 18)),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      await app.deleteContact(contact['id'] as int);
      app.speak('已刪除 ${contact['name']}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = context.watch<AppProvider>().contacts;

    return GestureDetector(
      onHorizontalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 300) Navigator.pop(context);
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('緊急連絡人'),
        backgroundColor: const Color(0xFF0D0D0D),
        automaticallyImplyLeading: false,
      ),
      body: Column(
        children: [
          // ── 說明文字 ─────────────────────────────────────────────────
          Container(
            width: double.infinity,
            color: const Color(0xFF0D0D0D),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
            child: const Text(
              '點擊連絡人直接撥打電話　長按可編輯或刪除',
              style: TextStyle(fontSize: 14, color: Colors.white38),
            ),
          ),

          // ── 連絡人清單 ───────────────────────────────────────────────
          Expanded(
            child: contacts.isEmpty
                ? _EmptyHint()
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount:   contacts.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: 4),
                    itemBuilder: (ctx, i) {
                      final c = contacts[i];
                      return _ContactBlock(
                        name:    c['name']  as String,
                        phone:   c['phone'] as String,
                        index:   i,
                        onTap:   () {
                          HapticFeedback.heavyImpact();
                          final app = context.read<AppProvider>();
                          app.speak('撥打給 ${c['name']}');
                          app.callContact(
                            c['name']  as String,
                            c['phone'] as String,
                          );
                        },
                        onLongPress: () => _showOptions(ctx, c),
                      );
                    },
                  ),
          ),

          // ── 新增連絡人大按鈕（底部）──────────────────────────────────
          SafeArea(
            top: false,
            child: Semantics(
              label:  '新增緊急連絡人',
              button: true,
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ContactFormScreen(slot: 0),
                    ),
                  );
                },
                child: Container(
                  width:   double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  color:   const Color(0xFF1565C0),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add, color: Colors.white, size: 34),
                      SizedBox(width: 12),
                      Text(
                        '新增緊急連絡人',
                        style: TextStyle(
                          fontSize:   26,
                          fontWeight: FontWeight.bold,
                          color:      Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      ), // Scaffold
    );   // GestureDetector
  }
}

// ── 連絡人大色塊 ──────────────────────────────────────────────────────────────
class _ContactBlock extends StatelessWidget {
  final String   name;
  final String   phone;
  final int      index;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  // 每位連絡人用不同深色調區分
  static const _colors = [
    Color(0xFF0D47A1), // 深藍
    Color(0xFF1B5E20), // 深綠
    Color(0xFF4A148C), // 深紫
    Color(0xFFE65100), // 深橘
    Color(0xFF880E4F), // 深粉
  ];

  const _ContactBlock({
    required this.name,
    required this.phone,
    required this.index,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final color = _colors[index % _colors.length];
    return Semantics(
      label:  '第${index + 1}位緊急聯絡人，$name，電話$phone，點擊撥打電話，長按可編輯或刪除',
      button: true,
      child: GestureDetector(
        onTap:       onTap,
        onLongPress: onLongPress,
        child: Container(
          width:   double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
          color:   color,
          child: Row(
            children: [
              // 電話圖示（視覺提示：可撥打）
              const Icon(Icons.phone, color: Colors.white70, size: 36),
              const SizedBox(width: 20),
              // 名稱 + 電話
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize:   32,
                        fontWeight: FontWeight.bold,
                        color:      Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      phone,
                      style: const TextStyle(
                        fontSize: 20,
                        color:    Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 空白提示 ─────────────────────────────────────────────────────────────────
class _EmptyHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.contacts, size: 72, color: Colors.white24),
            SizedBox(height: 20),
            Text(
              '尚未設定緊急連絡人',
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white54),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 12),
            Text(
              '點擊下方「新增緊急連絡人」\n設定後可語音說「打給媽媽」自動撥號',
              style: TextStyle(fontSize: 16, color: Colors.white30),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ── BottomSheet 選項列 ────────────────────────────────────────────────────────
class _BottomSheetBtn extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color    color;
  final VoidCallback onTap;

  const _BottomSheetBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label:  label,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 24),
          child: Row(
            children: [
              Icon(icon, color: color, size: 32),
              const SizedBox(width: 20),
              Text(label,
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: color)),
            ],
          ),
        ),
      ),
    );
  }
}
