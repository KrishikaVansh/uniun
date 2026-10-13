#define MyAppName "UNIUN"
#define MyAppVersion "3.1.0"
#define MyAppPublisher "UNIUN"
#define MyAppURL "https://www.uniun.in"
#define MyAppExeName "uniun.exe"
#define MyAppId "{{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}"
#define SourceDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\UNIUN
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir=..\installer\output
OutputBaseFilename=uniun-setup-v{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"

[Files]
; Main executable
Source: "{#SourceDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

; Flutter runtime
Source: "{#SourceDir}\flutter_windows.dll"; DestDir: "{app}"; Flags: ignoreversion

; AI / LiteRT engine DLLs
Source: "{#SourceDir}\LiteRt.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\LiteRtDispatch.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\LiteRtLm.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\LiteRtTopKWebGpuSampler.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\LiteRtWebGpuAccelerator.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\libLiteRt.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\libLiteRtTopKWebGpuSampler.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\libLiteRtWebGpuAccelerator.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\libwebgpu_dawn.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\webgpu_dawn.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\dxcompiler.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\dxil.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\GemmaModelConstraintProvider.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\libGemmaModelConstraintProvider.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\StreamProxy.dll"; DestDir: "{app}"; Flags: ignoreversion

; OpenVINO NPU
Source: "{#SourceDir}\openvino.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\openvino_intel_npu_compiler.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\openvino_intel_npu_compiler_loader.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\openvino_intel_npu_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\openvino_tensorflow_lite_frontend.dll"; DestDir: "{app}"; Flags: ignoreversion

; TBB (Intel Threading)
Source: "{#SourceDir}\tbb12.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\tbbbind_2_5.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\tbbmalloc.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\tbbmalloc_proxy.dll"; DestDir: "{app}"; Flags: ignoreversion

; Flutter plugin DLLs
Source: "{#SourceDir}\bonsoir_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\connectivity_plus_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\file_selector_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\flutter_gemma_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\flutter_secure_storage_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\isar_community_flutter_libs_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\openmls_frb.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\pdfium.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\share_plus_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\url_launcher_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\libisar.dll"; DestDir: "{app}"; Flags: ignoreversion

; Flutter assets (data folder — recursive)
Source: "{#SourceDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
