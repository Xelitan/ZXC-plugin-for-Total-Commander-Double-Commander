library ZXCWCX;

// ZXC plugin for Total Commander / Double Commander
// Uses pure Pascal ZXC library, no external dependencies
// License: MIT
// Author: www.xelitan.com

{$mode objfpc}{$H+}
{$E wcx64}

uses
  Windows, SysUtils, Classes, ZXCSimple, WcxPlugin;

type
  PZXCArchive = ^TZXCArchive;
  TZXCArchive = record
    ArchiveName: UnicodeString;
    EntryName: UnicodeString;
    Index, OpenMode: Integer;
    ChangeVolProcW: TChangeVolProcW;
    ProcessDataProcW: TProcessDataProcW;
  end;

procedure Log(const S: string);
var
  F: TextFile;
  Buf: array[0..MAX_PATH] of Char;
  FN: string;
begin
  Exit; //no need to log now
  try
    FillChar(Buf, SizeOf(Buf), 0);
    if GetModuleFileName(HInstance, Buf, MAX_PATH) <> 0 then
      FN := ExtractFilePath(StrPas(Buf)) + 'ZXC_log.txt'
    else
      FN := 'ZXC_log.txt';
    AssignFile(F, FN);
    if FileExists(FN) then Append(F) else Rewrite(F);
    try
      WriteLn(F, FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now), '  ', S);
    finally
      CloseFile(F);
    end;
  except
  end;
end;

function PtrStr(P: Pointer): string;
begin
  if P = nil then Result := 'nil'
  else Result := '$' + IntToHex(PtrUInt(P), SizeOf(Pointer) * 2);
end;

function WideStr(P: PWideChar): string;
begin
  try
    if P = nil then Result := '<nil>' else Result := Copy(string(UnicodeString(P)), 1, 300);
  except
    Result := '<bad PWideChar ' + PtrStr(P) + '>';
  end;
end;

function AnsiStr(P: PAnsiChar): string;
begin
  try
    if P = nil then Result := '<nil>' else Result := Copy(string(AnsiString(P)), 1, 300);
  except
    Result := '<bad PAnsiChar ' + PtrStr(P) + '>';
  end;
end;

procedure CopyAnsi(const S: AnsiString; var Buf; MaxChars: Integer);
var N: Integer;
begin
  FillChar(Buf, MaxChars, 0);
  N := Length(S);
  if N > MaxChars - 1 then N := MaxChars - 1;
  if N > 0 then Move(PAnsiChar(S)^, Buf, N);
end;

procedure CopyWide(const S: UnicodeString; var Buf; MaxChars: Integer);
var N: Integer;
begin
  FillChar(Buf, MaxChars * SizeOf(WideChar), 0);
  N := Length(S);
  if N > MaxChars - 1 then N := MaxChars - 1;
  if N > 0 then Move(PWideChar(S)^, Buf, N * SizeOf(WideChar));
end;

function DosTime(DT: TDateTime): LongInt;
var Y, M, D, H, N, S, MS: Word;
begin
  Result := 0;
  if DT <= 0 then Exit;
  DecodeDate(DT, Y, M, D);
  DecodeTime(DT, H, N, S, MS);
  if Y < 1980 then Y := 1980;
  Result := LongInt(((Y - 1980) shl 25) or (M shl 21) or (D shl 16) or
                    (H shl 11) or (N shl 5) or (S div 2));
end;

function IsZXCFileName(const FN: UnicodeString): Boolean;
begin
  Result := SameText(ExtractFileExt(String(FN)), '.ZXC');
end;

function MakeEntryName(const ArchiveName: UnicodeString): UnicodeString;
var
  S: UnicodeString;
begin
  S := UnicodeString(ExtractFileName(String(ArchiveName)));
  if SameText(ExtractFileExt(String(S)), '.ZXC') then
    Delete(S, Length(S) - Length('.ZXC') + 1, Length('.ZXC'));
  if S = '' then S := 'data';
  Result := S;
end;

function TestZXCArchive(const ArchiveName: UnicodeString): Boolean;
var
  InFile: TFileStream;
  OutFile: TMemoryStream;
begin
  Result := False;
  InFile := nil;
  OutFile := nil;
  try
    try
      InFile := TFileStream.Create(String(ArchiveName), fmOpenRead or fmShareDenyWrite);
      OutFile := TMemoryStream.Create;
      Result := ZXCDecompressStreams(InFile, OutFile) = 0;
    except
      Result := False;
    end;
  finally
    OutFile.Free;
    InFile.Free;
  end;
end;

function OpenArchiveW(var ArchiveData: tOpenArchiveDataW): THandle; stdcall;
var A: PZXCArchive;
begin
  Log('OpenArchiveW name=' + WideStr(ArchiveData.ArcName) + ' mode=' + IntToStr(ArchiveData.OpenMode));
  Result := 0;
  ArchiveData.OpenResult := E_BAD_ARCHIVE;
  New(A);
  FillChar(A^, SizeOf(A^), 0);
  try
    A^.ArchiveName := UnicodeString(ArchiveData.ArcName);
    A^.EntryName := MakeEntryName(A^.ArchiveName);
    A^.Index := -1;
    A^.OpenMode := ArchiveData.OpenMode;
    if not FileExists(String(A^.ArchiveName)) then
      ArchiveData.OpenResult := E_EOPEN
    else if IsZXCFileName(A^.ArchiveName) then
    begin
      // In extract mode defer full validation until ProcessFileW, so large archives
      // are not decompressed twice. In list mode we validate by trying to decompress
      // the first stream using ZXCDecompressStreams.
      if (ArchiveData.OpenMode = PK_OM_EXTRACT) or TestZXCArchive(A^.ArchiveName) then
      begin
        ArchiveData.OpenResult := E_SUCCESS;
        Exit(THandle(A));
      end;
    end;
    Dispose(A);
  except
    Dispose(A);
    ArchiveData.OpenResult := E_BAD_ARCHIVE;
  end;
end;

function ReadHeaderExW(hArcData: THandle; var HeaderData: THeaderDataExW): Integer; stdcall;
var
  A: PZXCArchive;
  SR: TSearchRec;
  DT: TDateTime;
  PackSize: Int64;
begin
  Log('ReadHeaderExW h=' + IntToStr(hArcData));
  FillChar(HeaderData, SizeOf(HeaderData), 0);
  Result := E_BAD_ARCHIVE;
  A := PZXCArchive(hArcData);
  if A = nil then Exit;

  Inc(A^.Index);
  if A^.Index > 0 then Exit(E_END_ARCHIVE);

  DT := 0;
  PackSize := 0;
  if FindFirst(String(A^.ArchiveName), faAnyFile, SR) = 0 then
  begin
    DT := FileDateToDateTime(SR.Time);
    PackSize := SR.Size;
    FindClose(SR);
  end;

  CopyWide(A^.ArchiveName, HeaderData.ArcName, 1024);
  CopyWide(A^.EntryName, HeaderData.FileName, 1024);
  HeaderData.UnpSize := 0;      // ZXCSimple API does not expose metadata up front.
  HeaderData.UnpSizeHigh := 0;
  HeaderData.PackSize := LongWord(UInt64(PackSize) and $FFFFFFFF);
  HeaderData.PackSizeHigh := LongWord(UInt64(PackSize) shr 32);
  HeaderData.FileTime := DosTime(DT);
  HeaderData.FileAttr := FILE_ATTRIBUTE_ARCHIVE;
  HeaderData.UnpVer := 29;
  HeaderData.Method := 0;
  Log('Header OK: ' + string(A^.EntryName));
  Result := E_SUCCESS;
end;

function BuildDest(A: PZXCArchive; DestPath, DestName: PWideChar): UnicodeString;
var Base: UnicodeString;
begin
  Result := '';
  if (A = nil) or (A^.Index <> 0) then Exit;
  if DestName <> nil then Result := UnicodeString(DestName);
  if Result = '' then Result := A^.EntryName;
  if DestPath <> nil then Base := UnicodeString(DestPath) else Base := '';
  if (Base <> '') and not ((Result[1] = '\') or ((Length(Result) > 1) and (Result[2] = ':'))) then
    Result := IncludeTrailingPathDelimiter(Base) + Result;
end;

function ProcessFileW(hArcData: THandle; Operation: Integer; DestPath, DestName: PWideChar): Integer; stdcall;
var
  A: PZXCArchive;
  OutName: UnicodeString;
  Dir: String;
  InFile: TFileStream;
  OutMem: TMemoryStream;
  R: Integer;
begin
  Log('ProcessFileW h=' + IntToStr(hArcData) + ' op=' + IntToStr(Operation) +
      ' path=' + WideStr(DestPath) + ' name=' + WideStr(DestName));
  Result := E_SUCCESS;
  try
    A := PZXCArchive(hArcData);
    if A = nil then Exit(E_BAD_ARCHIVE);

    case Operation of
      PK_SKIP:
        Exit(E_SUCCESS);
      PK_TEST:
        begin
          InFile := nil;
          OutMem := nil;
          try
            InFile := TFileStream.Create(String(A^.ArchiveName), fmOpenRead or fmShareDenyWrite);
            OutMem := TMemoryStream.Create;
            R := ZXCDecompressStreams(InFile, OutMem);
          finally
            OutMem.Free;
            InFile.Free;
          end;
          if R <> 0 then Result := E_BAD_DATA;
          Exit;
        end;
      PK_EXTRACT: ;
    else
      Exit(E_NOT_SUPPORTED);
    end;

    OutName := BuildDest(A, DestPath, DestName);
    if OutName = '' then Exit(E_SUCCESS);

    Dir := ExtractFileDir(String(OutName));
    if Dir <> '' then ForceDirectories(Dir);

    R := ZXCDecompressFile(String(A^.ArchiveName), String(OutName));
    if R <> 0 then Result := E_BAD_DATA;
  except
    on E: EOutOfMemory do Result := E_NO_MEMORY;
    on E: EFCreateError do Result := E_ECREATE;
    on E: EFOpenError do Result := E_EOPEN;
    on E: EFilerError do Result := E_EWRITE;
    on E: Exception do Result := E_BAD_DATA;
  end;
end;

function CloseArchive(hArcData: THandle): Integer; stdcall;
var A: PZXCArchive;
begin
  Log('CloseArchive h=' + IntToStr(hArcData));
  A := PZXCArchive(hArcData);
  if A <> nil then Dispose(A);
  Result := E_SUCCESS;
end;

procedure SetChangeVolProcW(hArcData: THandle; pChangeVolProc1: TChangeVolProcW); stdcall;
var A: PZXCArchive;
begin
  Log('SetChangeVolProcW h=' + IntToStr(hArcData) + ' proc=' + PtrStr(Pointer(pChangeVolProc1)));
  A := PZXCArchive(hArcData);
  if A <> nil then A^.ChangeVolProcW := pChangeVolProc1;
end;

procedure SetProcessDataProcW(hArcData: THandle; pProcessDataProc: TProcessDataProcW); stdcall;
var A: PZXCArchive;
begin
  Log('SetProcessDataProcW h=' + IntToStr(hArcData) + ' proc=' + PtrStr(Pointer(pProcessDataProc)));
  A := PZXCArchive(hArcData);
  if A <> nil then A^.ProcessDataProcW := pProcessDataProc;
end;

procedure SetCryptCallbackW(pCryptProc: TPkCryptProcW; CryptoNr, Flags: Integer); stdcall;
begin
  Log('SetCryptCallbackW ignored');
end;

function GetPackerCaps: Integer; stdcall;
begin
  Log('GetPackerCaps');
  Result := PK_CAPS_BY_CONTENT;
end;

function CanYouHandleThisFileW(FileName: PWideChar): Boolean; stdcall;
begin
  Log('CanYouHandleThisFileW name=' + WideStr(FileName));
  Result := IsZXCFileName(UnicodeString(FileName));
end;

{ ANSI compatibility exports: keep them because TC may probe classic WCX names. }
function OpenArchive(var ArchiveData: tOpenArchiveData): THandle; stdcall;
var W: tOpenArchiveDataW; N: UnicodeString;
begin
  Log('OpenArchive name=' + AnsiStr(ArchiveData.ArcName));
  FillChar(W, SizeOf(W), 0);
  N := UnicodeString(AnsiString(ArchiveData.ArcName));
  W.ArcName := PWideChar(N);
  W.OpenMode := ArchiveData.OpenMode;
  Result := OpenArchiveW(W);
  ArchiveData.OpenResult := W.OpenResult;
  ArchiveData.CmtSize := W.CmtSize;
  ArchiveData.CmtState := W.CmtState;
end;

function ReadHeaderEx(hArcData: THandle; var HeaderData: THeaderDataEx): Integer; stdcall;
var W: THeaderDataExW;
begin
  Log('ReadHeaderEx h=' + IntToStr(hArcData));
  FillChar(HeaderData, SizeOf(HeaderData), 0);
  Result := ReadHeaderExW(hArcData, W);
  if Result <> E_SUCCESS then Exit;
  CopyAnsi(AnsiString(UnicodeString(PWideChar(@W.ArcName[0]))), HeaderData.ArcName, 1024);
  CopyAnsi(AnsiString(UnicodeString(PWideChar(@W.FileName[0]))), HeaderData.FileName, 1024);
  HeaderData.Flags := W.Flags;
  HeaderData.PackSize := W.PackSize;
  HeaderData.PackSizeHigh := W.PackSizeHigh;
  HeaderData.UnpSize := W.UnpSize;
  HeaderData.UnpSizeHigh := W.UnpSizeHigh;
  HeaderData.HostOS := W.HostOS;
  HeaderData.FileCRC := W.FileCRC;
  HeaderData.FileTime := W.FileTime;
  HeaderData.UnpVer := W.UnpVer;
  HeaderData.Method := W.Method;
  HeaderData.FileAttr := W.FileAttr;
  HeaderData.CmtSize := W.CmtSize;
  HeaderData.CmtState := W.CmtState;
end;

function ReadHeader(hArcData: THandle; var HeaderData: THeaderData): Integer; stdcall;
var Ex: THeaderDataEx;
begin
  Log('ReadHeader h=' + IntToStr(hArcData));
  FillChar(HeaderData, SizeOf(HeaderData), 0);
  Result := ReadHeaderEx(hArcData, Ex);
  if Result <> E_SUCCESS then Exit;
  CopyAnsi(PAnsiChar(@Ex.ArcName[0]), HeaderData.ArcName, 260);
  CopyAnsi(PAnsiChar(@Ex.FileName[0]), HeaderData.FileName, 260);
  HeaderData.Flags := Ex.Flags;
  HeaderData.PackSize := Ex.PackSize;
  HeaderData.UnpSize := Ex.UnpSize;
  HeaderData.HostOS := Ex.HostOS;
  HeaderData.FileCRC := Ex.FileCRC;
  HeaderData.FileTime := Ex.FileTime;
  HeaderData.UnpVer := Ex.UnpVer;
  HeaderData.Method := Ex.Method;
  HeaderData.FileAttr := Ex.FileAttr;
  HeaderData.CmtSize := Ex.CmtSize;
  HeaderData.CmtState := Ex.CmtState;
end;

function ProcessFile(hArcData: THandle; Operation: Integer; DestPath, DestName: PAnsiChar): Integer; stdcall;
var WP, WN: UnicodeString; P1, P2: PWideChar;
begin
  Log('ProcessFile h=' + IntToStr(hArcData) + ' op=' + IntToStr(Operation) +
      ' path=' + AnsiStr(DestPath) + ' name=' + AnsiStr(DestName));
  try
    P1 := nil; P2 := nil;
    if DestPath <> nil then begin WP := UnicodeString(AnsiString(DestPath)); P1 := PWideChar(WP); end;
    if DestName <> nil then begin WN := UnicodeString(AnsiString(DestName)); P2 := PWideChar(WN); end;
    Result := ProcessFileW(hArcData, Operation, P1, P2);
  except
    Result := E_BAD_DATA;
  end;
end;

procedure SetChangeVolProc(hArcData: THandle; pChangeVolProc1: TChangeVolProc); stdcall;
begin
  Log('SetChangeVolProc h=' + IntToStr(hArcData) + ' proc=' + PtrStr(Pointer(pChangeVolProc1)));
end;

procedure SetProcessDataProc(hArcData: THandle; pProcessDataProc: TProcessDataProc); stdcall;
begin
  Log('SetProcessDataProc h=' + IntToStr(hArcData) + ' proc=' + PtrStr(Pointer(pProcessDataProc)));
end;

procedure SetCryptCallback(pCryptProc: TPkCryptProc; CryptoNr, Flags: Integer); stdcall;
begin
  Log('SetCryptCallback ignored');
end;

function CanYouHandleThisFile(FileName: PAnsiChar): Boolean; stdcall;
begin
  Log('CanYouHandleThisFile name=' + AnsiStr(FileName));
  Result := IsZXCFileName(UnicodeString(AnsiString(FileName)));
end;

exports
  OpenArchive name 'OpenArchive',
  OpenArchiveW name 'OpenArchiveW',
  ReadHeader name 'ReadHeader',
  ReadHeaderEx name 'ReadHeaderEx',
  ReadHeaderExW name 'ReadHeaderExW',
  ProcessFile name 'ProcessFile',
  ProcessFileW name 'ProcessFileW',
  CloseArchive name 'CloseArchive',
  SetChangeVolProc name 'SetChangeVolProc',
  SetChangeVolProcW name 'SetChangeVolProcW',
  SetProcessDataProc name 'SetProcessDataProc',
  SetProcessDataProcW name 'SetProcessDataProcW',
  SetCryptCallback name 'SetCryptCallback',
  SetCryptCallbackW name 'SetCryptCallbackW',
  GetPackerCaps name 'GetPackerCaps',
  CanYouHandleThisFile name 'CanYouHandleThisFile',
  CanYouHandleThisFileW name 'CanYouHandleThisFileW';

begin
  Log('library initialization');
end.
