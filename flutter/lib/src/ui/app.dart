/// App entry: MaterialApp + [AppModelScope] (an InheritedNotifier
/// that exposes the [AppModel] to every tab and pushed route).
library;

import 'package:material_ui/material_ui.dart';

import 'app_model.dart';
import 'root_view.dart';

class AppModelScope extends InheritedNotifier<AppModel> {
  const AppModelScope({
    super.key,
    required super.notifier,
    required super.child,
  });

  static AppModel of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<AppModelScope>();
    assert(scope != null, 'AppModelScope not found above this widget');
    return scope!.notifier!;
  }
}

class SimBridgeApp extends StatelessWidget {
  const SimBridgeApp({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    return AppModelScope(
      notifier: model,
      child: MaterialApp(
        locale: const Locale('fa'),
        title: 'پل سیم‌کارت',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const RootView(),
      ),
    );
  }
}
