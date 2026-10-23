import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final environment = <String, String>{};
    if (input.config.buildCodeAssets &&
        input.config.code.targetOS == OS.android) {
      final target = switch (input.config.code.targetArchitecture) {
        Architecture.arm64 => 'aarch64-linux-android',
        Architecture.arm => 'armv7-linux-androideabi',
        Architecture.x64 => 'x86_64-linux-android',
        _ => throw UnsupportedError('Unsupported Android ABI'),
      };
      final ndkTarget = target == 'armv7-linux-androideabi'
          ? 'armv7a-linux-androideabi'
          : target;
      final bin = File.fromUri(input.config.code.cCompiler!.compiler).parent;
      final suffix = Platform.isWindows ? '.cmd' : '';
      final key = target.replaceAll('-', '_');
      // native_toolchain_rust 1.0.4 defaults to API 35. Preserve BRIZFI API 29.
      environment['CC_$key'] =
          '${bin.path}/$ndkTarget'
          '29-clang$suffix';
      environment['CXX_$key'] =
          '${bin.path}/$ndkTarget'
          '29-clang++$suffix';
      environment['CARGO_TARGET_${key.toUpperCase()}_LINKER'] =
          environment['CC_$key']!;
    }
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
      extraCargoBuildArgs: const ['--locked'],
      extraCargoEnvironmentVariables: environment,
    ).run(input: input, output: output);
  });
}
