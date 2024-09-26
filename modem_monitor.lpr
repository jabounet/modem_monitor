program ModemMonitor;

{$mode objfpc}{$H+}
{$SMARTLINK ON}
{$Optimization ON}
{$INLINE ON}

uses
  Classes,
  SysUtils,
  Forms,
  Controls,
  Graphics,
  Dialogs,
  Menus,
  IniFiles,
  LCLIntf,
  LCLType,
  ExtCtrls,
  Interfaces,
  synaser,
  Windows,
  Registry;

type
  StrArray = array of string;

var
  MutexHandle: THandle;


type

  { TModemMonitorApp }

  TModemMonitorApp = class(TObject)
  private
    ser: TBlockSerial;
    modemPort: string;
    trayIcon: TTrayIcon;
    popupMenu: TPopupMenu;
    exitItem: TMenuItem;
    numero: string;
    paths: array of string;
    procedure SaveNumeroToFile;

    procedure ConnectModem;
    procedure TrayIconClick(Sender: TObject);
    procedure TrayIconRightClick(Sender: TObject);
    procedure ExitApp(Sender: TObject);
    procedure MainLoop;
    function GetPathsArray: StrArray;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;


   function GetIniParam(const Section, Ident: string): string;
  var
    Ini: TIniFile;
    FileName: String;
  begin
    FileName := ExtractFilePath(ParamStr(0)) + 'params.ini';
    if not FileExists(FileName) then
    begin
      ShowMessage('Erreur : le fichier de configuration est absent');
      Application.Terminate;
      exit;
    end;
    Ini := TIniFile.Create(FileName);
    try
      Result := Ini.ReadString(Section, Ident, '');
    finally
      Ini.Free;
    end;
  end;



  procedure AddApplicationToStartup(const AppName, AppPath: string);
  var
    Reg: TRegistry;
  begin
    Reg := TRegistry.Create;
    try
      // Ouvrir la clé de registre Run
      Reg.RootKey := HKEY_CURRENT_USER;
      if Reg.OpenKey('Software\Microsoft\Windows\CurrentVersion\Run', True) then
      begin
        try
          // Ajouter l'application à la clé de registre Run
          Reg.WriteString(AppName, AppPath);
        finally
          Reg.CloseKey;
        end;
      end;
    finally
      Reg.Free;
    end;
  end;

  function IsAlreadyRunning: boolean;
  begin
    MutexHandle := CreateMutex(nil, True, 'JSMS_SerialPortMonitor');
    Result := (MutexHandle = 0) or (GetLastError = ERROR_ALREADY_EXISTS);
  end;


  function EnsureTrailingBackslash(const Path: string): string;
  begin

    if (Path <> '') and (Path[Length(Path)] <> '\') then
      Result := Path + '\'
    else
      Result := Path;
  end;



  procedure TModemMonitorApp.SaveNumeroToFile;
  var
    logFile: TextFile;
    logFilePath: string;
  var
    i: integer;
  begin
    if length(paths) = 0 then exit;
    for i := 0 to high(paths) do
    begin

      logFilePath := paths[i] + format('call_%s.txt', [numero]);
      AssignFile(logFile, logFilePath);
      if FileExists(logFilePath) then
        Append(logFile)
      else
        Rewrite(logFile);
      WriteLn(logFile, numero);
      CloseFile(logFile);
    end;
  end;



  function TModemMonitorApp.GetPathsArray: StrArray;
  var

    PathsString: string;
    PathsList: TStringList;
    i: integer;
  begin
    SetLength(Result, 0);
      PathsString := GetIniParam('params', 'PATHS');
      PathsList := TStringList.Create;
      try
        PathsList.Delimiter := ';';
        PathsList.StrictDelimiter := True;
        PathsList.DelimitedText := PathsString;
        SetLength(Result, PathsList.Count);
        for i := 0 to PathsList.Count - 1 do
        begin
          Result[i] := EnsureTrailingBackslash(PathsList[i]);
        end;
      finally
        PathsList.Free;
      end;
  end;

  procedure TModemMonitorApp.ConnectModem;
  var
    inif: string;
  begin
    try
      ser := TBlockSerial.Create;
      ser.RaiseExcept := False;
      ser.LinuxLock := False;
      ser.Connect(modemPort);
      ser.Config(115200, 8, 'N', SB1, False, False);

      if ser.LastError <> 0 then
      begin
        ShowMessage('Erreur de connexion au port COM du modem.');
        Application.Terminate;
        exit;
      end;

      ser.RTS := True;
      ser.DTR := True;
      ser.SendString('AT+VCID=1' + #13#10); // Requete pour voir l'identifiant appelant

    except
      on E: Exception do
        ShowMessage('Exception: ' + E.Message);
    end;
  end;

  procedure TModemMonitorApp.TrayIconClick(Sender: TObject);
  begin
    // Event handler for tray icon click
    ShowMessage('ModemMonitor is running. Right-click to exit.');
  end;

  procedure TModemMonitorApp.TrayIconRightClick(Sender: TObject);
  begin
    popupMenu.PopUp(Mouse.CursorPos.X, Mouse.CursorPos.Y);
  end;

  procedure TModemMonitorApp.ExitApp(Sender: TObject);
  begin
    Application.Terminate;
  end;

  procedure TModemMonitorApp.MainLoop;
  var
    S1: string;
    x, y: integer;
  begin
    while not Application.Terminated do
    begin
      if ser.WaitingData > 0 then
      begin
        S1 := ser.RecvString(1000);
        x := Pos('NMBR', S1);

        if x <> 0 then
        begin
          y := x + 6;
          repeat
            Inc(y);
          until (Ord(S1[y]) > 57) or (Ord(S1[y]) < 48);

          numero := Copy(S1, x + 5, y - x - 5);
          if numero[1] = 'P' then
            numero := 'inconnu';

          SaveNumeroToFile;
        end;
      end;
      Sleep(100);
      Application.ProcessMessages;
    end;
  end;

  constructor TModemMonitorApp.Create;
  var
    curpath, inif: string;
    i: integer;
  begin
    ser := TBlockSerial.Create;
    trayIcon := TTrayIcon.Create(nil);
    trayIcon.Icon := Application.Icon;
    trayIcon.Hint := 'Moniteur d''appels - Jabouley Florent';
    //trayIcon.OnClick := @TrayIconClick;
    trayIcon.OnClick := @TrayIconRightClick;
    trayIcon.Visible := True;

    popupMenu := TPopupMenu.Create(nil);
    exitItem := TMenuItem.Create(popupMenu);
    exitItem.Caption := 'Quitter';
    exitItem.OnClick := @ExitApp;
    popupMenu.Items.Add(exitItem);


    if modemPort = '' then
    begin
      modemPort := GetIniParam('params', 'COM_PORT');
    end;

    paths := GetPathsArray;
    //   for i := 0 to high(paths) do ShowMessage(paths[i]);
    if length(paths) = 0 then
    begin
      ShowMessage('Erreur, aucun dossier d''export n''a été spécifié dans le fichier de paramètres');
      Application.terminate;
      exit;
    end;
  end;

  destructor TModemMonitorApp.Destroy;
  begin
    ser.Free;
    trayIcon.Free;
    popupMenu.Free;
    inherited Destroy;
  end;

  procedure TModemMonitorApp.Run;
  begin
    ConnectModem;
    MainLoop;
  end;

var
  App: TModemMonitorApp;

{$R *.res}

begin
  Application.Title:='Moniteur d''appels - Jabouley Florent';
  Application.Initialize;
  Application.MainFormOnTaskBar := True;
  if IsAlreadyRunning then
  begin
    ShowMessage('L''application est déjà en cours de fonctionnement, impossible de continuer');
    Application.Terminate;
    exit;
  end;
  if UpperCase(GetIniParam('params','Start_With_Windows'))='TRUE' then AddApplicationToStartup('JSMS Serial Modem Monitor', paramstr(0));
  App := TModemMonitorApp.Create;
  try
    App.Run;

  finally
    App.Free;
  end;
end.
