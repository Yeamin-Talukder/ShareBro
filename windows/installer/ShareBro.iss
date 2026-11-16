; ShareBro for Windows: installer (Inno Setup 6, https://jrsoftware.org/isinfo.php).
;
; Build the app first, then the installer:
;   flutter build windows --release
;   "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" /DAppVersion=1.6.0 windows\installer\ShareBro.iss
;
; The installer lands in build\installer\ShareBro-<version>-windows-setup.exe.
; It installs for the current user (no admin prompt). Installed for all users
; (as admin), it also lets ShareBro through Windows Firewall on private
; networks, so phones on the same Wi-Fi can find the PC.

#ifndef AppVersion
  #define AppVersion "1.6.0"
#endif

#define AppName "ShareBro"
#define AppExe "photo_organizer.exe"
#define BuildDir "..\..\build\windows\x64\runner\Release"

[Setup]
; Never change AppId: Windows uses it to find the installed copy to update.
AppId={{6A0E3C51-3B5E-4E36-9C63-5B1F0E7A2B19}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=ShareBro
AppPublisherURL=https://github.com/Yeamin-Talukder/ShareBro
AppSupportURL=https://github.com/Yeamin-Talukder/ShareBro/issues
AppUpdatesURL=https://github.com/Yeamin-Talukder/ShareBro/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\..\build\installer
OutputBaseFilename={#AppName}-{#AppVersion}-windows-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Everything flutter build windows puts next to the app: the exe, the
; engine and plugin DLLs (ONNX Runtime among them) and the data folder with
; the face models.
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; Phones find the PC over the local network (LocalSend protocol, port 53317).
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""{#AppName}"" dir=in action=allow program=""{app}\{#AppExe}"" enable=yes profile=private"; Flags: runhidden; Check: IsAdminInstallMode; StatusMsg: "Allowing ShareBro on private networks..."
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#AppName}"" program=""{app}\{#AppExe}"""; Flags: runhidden; Check: IsAdminInstallMode; RunOnceId: "RemoveFirewallRule"

[UninstallDelete]
; The thumbnail cache. The database (your people and names) is kept, so a
; reinstall picks up where you left off.
Type: filesandordirs; Name: "{userappdata}\ShareBro\ShareBro\thumbs"
