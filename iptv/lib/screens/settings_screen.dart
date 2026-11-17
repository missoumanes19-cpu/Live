import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/parental_control.dart';

class SettingsScreen extends StatelessWidget {
  final List<String> categories;
  const SettingsScreen({super.key, required this.categories});
  @override
  Widget build(BuildContext context) {
    final pc = context.watch<ParentalControl>();
    return Scaffold(
      appBar: AppBar(title: const Text('الرقابة الأبوية')),
      body: ListView(children: [
        ListTile(
          leading: const Icon(Icons.lock), title: const Text('تغيير رمز PIN'),
          onTap: () async {
            final old = TextEditingController(), nw = TextEditingController();
            await showDialog(context: context, builder: (d) => AlertDialog(
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                if (pc.hasPin) TextField(controller: old, obscureText: true,
                    decoration: const InputDecoration(labelText: 'الرمز الحالي')),
                TextField(controller: nw, obscureText: true, maxLength: 4,
                    decoration: const InputDecoration(labelText: 'الرمز الجديد')),
              ]),
              actions: [TextButton(onPressed: () {
                final ok = pc.setPin(nw.text, oldPin: old.text);
                Navigator.pop(d);
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(ok ? 'تم الحفظ' : 'الرمز الحالي خاطئ')));
              }, child: const Text('حفظ'))],
            ));
          },
        ),
        const Divider(),
        for (final c in categories)
          SwitchListTile(title: Text(c), value: pc.isLocked(c),
              onChanged: (_) => pc.toggleCategory(c)),
      ]),
    );
  }
}
