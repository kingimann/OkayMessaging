import 'package:flutter/material.dart';

/// A key on the home `Scaffold`, so code outside the home screen (e.g. tests,
/// or a future shortcut) can reach home's drawer by key. The old
/// `SidebarMenuButton` (a ☰ shown on pushed sidebar destinations) is gone —
/// the owner's call: a pushed screen goes back with the normal back arrow,
/// and the sidebar is home's drawer alone.
final GlobalKey<ScaffoldState> homeScaffoldKey = GlobalKey<ScaffoldState>();
