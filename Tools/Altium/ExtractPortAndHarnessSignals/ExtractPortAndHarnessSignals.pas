{..............................................................................}
{ ExtractPortAndHarnessSignals.pas                                             }
{                                                                              }
{ For every schematic sheet of the currently focused project, lists:           }
{   - Port signals (ISch_Port.Name), flagging signal-harness ports             }
{   - Harness connectors: the signal-harness port that carries each harness    }
{     on that sheet (matched by harness type), and its individual signals      }
{                                                                              }
{ Read-only script: no document is modified. Altium Designer 23+.             }
{ Entry point to run: ExtractPortAndHarnessSignals                             }
{..............................................................................}

const
    // This script's own source file name, used to identify -- among every
    // project open in the workspace -- the Script project (.PrjScr) that
    // this script itself belongs to, so the report can be saved next to the
    // script rather than next to whichever design project is focused.
    SCRIPT_FILE_NAME = 'ExtractPortAndHarnessSignals.pas';

var
    // Script-level counters used for the final summary dialog
    GTotalSheets    : Integer;
    GTotalPorts     : Integer;
    GTotalHarnesses : Integer;

{..............................................................................}
{ Returns the Nth delimited field (0-based) from S, split on Delim.            }
{ Returns an empty string if FieldIndex is out of range.                       }
{..............................................................................}
function GetDelimField(S : String; FieldIndex : Integer; Delim : Char) : String;
var
    i, Start, Count : Integer;
begin
    Result := '';
    Start  := 1;
    Count  := 0;
    for i := 1 to Length(S) do
    begin
        if S[i] = Delim then
        begin
            if Count = FieldIndex then
            begin
                Result := Copy(S, Start, i - Start);
                Exit;
            end;
            Start := i + 1;
            Inc(Count);
        end;
    end;
    // Return the trailing text as the last field
    if Count = FieldIndex then
        Result := Copy(S, Start, Length(S) - Start + 1);
end;

{..............................................................................}
{ Returns the Nth pipe-delimited field (0-based) from S. Thin wrapper kept for }
{ compatibility with existing call sites (pipe is this script's default       }
{ record separator).                                                          }
{..............................................................................}
function GetPipeField(S : String; FieldIndex : Integer) : String;
begin
    Result := GetDelimField(S, FieldIndex, '|');
end;

{..............................................................................}
{ Returns the port name recorded in Names (rows are "HarnessType|PortName",    }
{ populated while scanning this sheet's Ports) whose HarnessType matches HType }
{ case-insensitively. Returns '' if no signal-harness port of that type was    }
{ found on this sheet.                                                        }
{..............................................................................}
function FindPortNameForHarnessType(Names : TStringList; HType : String) : String;
var
    n : Integer;
begin
    Result := '';
    for n := 0 to Names.Count - 1 do
    begin
        if UpperCase(GetPipeField(Names[n], 0)) = UpperCase(HType) then
        begin
            Result := GetPipeField(Names[n], 1);
            Exit;
        end;
    end;
end;

{..............................................................................}
{ Counts the number of Delim-separated fields in S. Returns 0 for ''.          }
{..............................................................................}
function CountDelimFields(S : String; Delim : Char) : Integer;
var
    i : Integer;
begin
    if S = '' then
    begin
        Result := 0;
        Exit;
    end;
    Result := 1;
    for i := 1 to Length(S) do
        if S[i] = Delim then Inc(Result);
end;

{..............................................................................}
{ True if any vertex encoded in VertexListStr ("x1,y1;x2,y2;...") lies within  }
{ 1 unit of (PX,PY).                                                          }
{..............................................................................}
function WireHasVertexNear(VertexListStr : String; PX, PY : Integer) : Boolean;
var
    n, i      : Integer;
    VertexStr : String;
    VX, VY    : Integer;
begin
    Result := False;
    if VertexListStr = '' then Exit;
    n := CountDelimFields(VertexListStr, ';');
    for i := 0 to n - 1 do
    begin
        VertexStr := GetDelimField(VertexListStr, i, ';');
        VX := StrToInt(GetDelimField(VertexStr, 0, ','));
        VY := StrToInt(GetDelimField(VertexStr, 1, ','));
        if (Abs(VX - PX) <= 1) and (Abs(VY - PY) <= 1) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

{..............................................................................}
{ Fills NetLabels with one "X|Y|Text" row per eNetLabel placed on SchDoc.      }
{..............................................................................}
procedure BuildNetLabelList(SchDoc : ISch_Document; NetLabels : TStringList);
var
    Iterator : ISch_Iterator;
    NetLabel : ISch_NetLabel;
begin
    NetLabels.Clear;
    Iterator := SchDoc.SchIterator_Create;
    try
        Iterator.AddFilter_ObjectSet(MkSet(eNetLabel));
        NetLabel := Iterator.FirstSchObject;
        while NetLabel <> nil do
        begin
            NetLabels.Add(IntToStr(NetLabel.Location.X) + '|' +
                          IntToStr(NetLabel.Location.Y) + '|' +
                          NetLabel.Text);
            NetLabel := Iterator.NextSchObject;
        end;
    finally
        SchDoc.SchIterator_Destroy(Iterator);
    end;
end;

{..............................................................................}
{ Fills Wires with one row per eWire on SchDoc, each row its full vertex list  }
{ "x1,y1;x2,y2;...;xn,yn".                                                    }
{..............................................................................}
procedure BuildWireList(SchDoc : ISch_Document; Wires : TStringList);
var
    Iterator  : ISch_Iterator;
    Wire      : ISch_Wire;
    VertexStr : String;
    v         : Integer;
begin
    Wires.Clear;
    Iterator := SchDoc.SchIterator_Create;
    try
        Iterator.AddFilter_ObjectSet(MkSet(eWire));
        Wire := Iterator.FirstSchObject;
        while Wire <> nil do
        begin
            VertexStr := '';
            for v := 1 to Wire.VerticesCount do
            begin
                if VertexStr <> '' then VertexStr := VertexStr + ';';
                VertexStr := VertexStr + IntToStr(Wire.Vertex[v].X) + ',' +
                                          IntToStr(Wire.Vertex[v].Y);
            end;
            if VertexStr <> '' then Wires.Add(VertexStr);
            Wire := Iterator.NextSchObject;
        end;
    finally
        SchDoc.SchIterator_Destroy(Iterator);
    end;
end;

{..............................................................................}
{ Returns the text of the net label that belongs to this SPECIFIC schematic    }
{ sheet's copy of a harness entry at (PX,PY) -- i.e. its own local "Net Name"   }
{ when a custom label is actually placed on THIS sheet, as opposed to the      }
{ final merged/flattened "Physical Name" every sheet shares once compiled     }
{ (see ResolveHarnessEntryNetName). Returns '' if no such label is found on    }
{ this sheet, in which case the caller falls back to the synthesized           }
{ "<PortName>.<EntryName>" display name.                                      }
{                                                                              }
{ Deliberately narrow, by design: checks only (a) a label sitting directly on  }
{ (PX,PY), and (b) a label reachable by exactly ONE wire hop from (PX,PY) --   }
{ the common case of a short stub wire leading from the harness entry out to   }
{ its label. This does NOT walk multiple chained wires, bus entries, or       }
{ 2-pin passives the way this file's original (removed) wire tracer did --    }
{ that full connectivity walk is a separate, larger feature; this is just a   }
{ single coincidence/one-hop check.                                           }
{..............................................................................}
function FindNetLabelAtOrNearPoint(NetLabels, Wires : TStringList; PX, PY : Integer) : String;
var
    i, n      : Integer;
    LX, LY    : Integer;
    VertexStr : String;
begin
    Result := '';

    // Direct hit: a net label sitting exactly on the entry's own anchor point.
    for i := 0 to NetLabels.Count - 1 do
    begin
        LX := StrToInt(GetPipeField(NetLabels[i], 0));
        LY := StrToInt(GetPipeField(NetLabels[i], 1));
        if (Abs(LX - PX) <= 1) and (Abs(LY - PY) <= 1) then
        begin
            Result := GetPipeField(NetLabels[i], 2);
            Exit;
        end;
    end;

    // One wire hop: the entry connects via a short stub wire whose OTHER end
    // sits at a net label's own point.
    for n := 0 to Wires.Count - 1 do
    begin
        VertexStr := Wires[n];
        if WireHasVertexNear(VertexStr, PX, PY) then
        begin
            for i := 0 to NetLabels.Count - 1 do
            begin
                LX := StrToInt(GetPipeField(NetLabels[i], 0));
                LY := StrToInt(GetPipeField(NetLabels[i], 1));
                if WireHasVertexNear(VertexStr, LX, LY) then
                begin
                    Result := GetPipeField(NetLabels[i], 2);
                    Exit;
                end;
            end;
        end;
    end;
end;

{..............................................................................}
{ Returns the resolved, compiled PHYSICAL net name for a Port named PortName    }
{ on PhysDoc (Doc's compiled physical counterpart, see GetPhysicalDocument) --  }
{ i.e. the same "Physical Name" shown in Altium's Net Properties panel.        }
{ PhysDoc.DM_Ports(i) returns one INetItem per placed port, whose .DM_NetName   }
{ equals the port's own declared name and ALREADY holds the real physical net  }
{ name directly (confirmed against a live report -- CANH/CANL resolved            }
{ correctly this way).                                                        }
{..............................................................................}
function ResolvePortNetName(PhysDoc : IDocument; PortName : String) : String;
var
    i    : Integer;
    Item : INetItem;
begin
    Result := '';
    if PhysDoc = nil then Exit;
    for i := 0 to PhysDoc.DM_PortCount - 1 do
    begin
        Item := PhysDoc.DM_Ports(i);
        if (Item <> nil) and (UpperCase(Item.DM_NetName) = UpperCase(PortName)) then
        begin
            Result := Item.DM_NetName;
            Exit;
        end;
    end;
end;

{..............................................................................}
{ Returns the physical net name of the harness-connector signal entry, on      }
{ PhysDoc, whose own location matches (X,Y) within NET_LOCATION_TOLERANCE.      }
{ PhysDoc.DM_HarnessConnectors(h) is each harness connector as an ISheetSymbol, }
{ whose DM_SheetEntryCount/DM_SheetEntries(e) give one INetItem per signal on   }
{ that connector -- its .DM_NetName ALREADY holds the real physical net name    }
{ directly (confirmed against a live diagnostic dump: entries named 'CAN0_RX'  }
{ and 'CAN0.TX' at the exact same (X,Y) as the corresponding native              }
{ eHarnessEntry's own .Location -- no .DM_OwnerNetPhysical hop needed, unlike   }
{ ResolvePortNetName's docs might suggest by analogy; that hop returns nil      }
{ here for reasons unconfirmed, which is exactly why three earlier attempts     }
{ that included it came back empty).                                          }
{                                                                              }
{ Call with the SAME eHarnessEntry's own .Location.X/Y from the native SCH      }
{ side, while that object is still valid.                                     }
{..............................................................................}
function ResolveHarnessEntryNetName(PhysDoc : IDocument; X, Y : Integer) : String;
const
    NET_LOCATION_TOLERANCE = 1;
var
    h, e : Integer;
    Conn : ISheetSymbol;
    Item : INetItem;
begin
    Result := '';
    if PhysDoc = nil then Exit;
    for h := 0 to PhysDoc.DM_HarnessConnectorCount - 1 do
    begin
        Conn := PhysDoc.DM_HarnessConnectors(h);
        if Conn = nil then Continue;
        for e := 0 to Conn.DM_SheetEntryCount - 1 do
        begin
            Item := Conn.DM_SheetEntries(e);
            if (Item <> nil) and
               (Abs(Item.DM_LocationX - X) <= NET_LOCATION_TOLERANCE) and
               (Abs(Item.DM_LocationY - Y) <= NET_LOCATION_TOLERANCE) then
            begin
                Result := Item.DM_NetName;
                Exit;
            end;
        end;
    end;
end;

{..............................................................................}
{ Returns the compiled PHYSICAL counterpart of LogicalDoc (a document from      }
{ Project.DM_LogicalDocuments), or LogicalDoc itself if it has none. This       }
{ matters because net/connectivity data (DM_Ports, DM_HarnessConnectors, and    }
{ friends) is only populated on the POST-compile "physical" document -- calling}
{ ResolvePortNetName/ResolveHarnessEntryNetName directly on the pre-compile     }
{ "logical" document (as this script originally did) silently returns no net,  }
{ so every port/harness signal comes back "(unresolved)" even for the           }
{ simplest, non-harness nets.                                                  }
{                                                                              }
{ For a flat (non-hierarchical, non-multi-channel) sheet there is exactly one  }
{ physical instance, so DM_PhysicalDocument(0) is the one wanted; a sheet      }
{ used more than once in the hierarchy would have more than one, but this      }
{ script only needs any single instance's connectivity to resolve a net name.  }
{                                                                              }
{ ASSUMPTION: IDocument.DM_PhysicalDocumentCount / DM_PhysicalDocument(i)       }
{ returns a logical document's own compiled physical instance(s) -- confirmed  }
{ present in Altium's published Workspace-Manager interface reference, but    }
{ not verified live in this environment; verify against Altium if this fails   }
{ to compile.                                                                  }
{..............................................................................}
function GetPhysicalDocument(LogicalDoc : IDocument) : IDocument;
begin
    Result := LogicalDoc;
    if (LogicalDoc <> nil) and (LogicalDoc.DM_PhysicalDocumentCount > 0) then
        Result := LogicalDoc.DM_PhysicalDocument(0);
end;

{..............................................................................}
{ Searches every project currently open in the workspace for the one that     }
{ owns this script's own source file (SCRIPT_FILE_NAME) among its logical     }
{ documents, and returns that project's folder -- i.e. the folder containing  }
{ ExtractPortAndHarnessSignals.PrjScr. Returns '' if it can't be found (e.g.   }
{ the script was somehow run from outside its own Script project).            }
{                                                                              }
{ ASSUMPTION: IWorkspace exposes DM_ProjectCount / DM_Projects(i), mirroring  }
{ the IProject.DM_LogicalDocumentCount / DM_LogicalDocuments(i) pattern       }
{ already used elsewhere in this file -- verify against the live Altium API   }
{ if this fails to compile.                                                   }
{..............................................................................}
function GetScriptProjectFolder(WS : IWorkspace) : String;
var
    p, d    : Integer;
    Proj    : IProject;
    Doc     : IDocument;
begin
    Result := '';
    for p := 0 to WS.DM_ProjectCount - 1 do
    begin
        Proj := WS.DM_Projects(p);
        for d := 0 to Proj.DM_LogicalDocumentCount - 1 do
        begin
            Doc := Proj.DM_LogicalDocuments(d);
            if UpperCase(Doc.DM_FileName) = UpperCase(SCRIPT_FILE_NAME) then
            begin
                Result := ExtractFilePath(Proj.DM_ProjectFullPath);
                Exit;
            end;
        end;
    end;
end;

{..............................................................................}
{ Collects ports and harness connectors of one schematic sheet into the       }
{ report list. Doc is the SAME sheet's compiled Workspace-Manager document     }
{ (as opposed to SchDoc, the native SCH object-model document) -- it is only   }
{ used to resolve Doc's compiled physical document (see GetPhysicalDocument).  }
{..............................................................................}
procedure ProcessSchematicSheet(SchDoc : ISch_Document; Doc : IDocument; Report : TStringList);
var
    Iterator      : ISch_Iterator;
    GroupIterator : ISch_Iterator;
    Port          : ISch_Port;
    Harness       : ISch_HarnessConnector;
    Child         : ISch_GraphicalObject;
    HarnessType   : String;
    PortLine      : String;
    PortCount     : Integer;
    HarnessCount  : Integer;
    EntryList     : TStringList;   // individual entry names per harness connector
    k             : Integer;       // loop index for EntryList
    SheetFile     : String;        // cached sheet filename (used in multiple places)
    HarnessPortNames   : TStringList; // "HarnessType|PortName" rows, from THIS sheet's signal-harness ports
    PortNameForHarness : String;
    QualifiedPrefix    : String;   // PortName (or HarnessType fallback) used to qualify entry signal names
    QualifiedName      : String;   // "<QualifiedPrefix>.<EntryName>"
    NetName            : String;   // resolved physical net name for the current Port/Harness entry
    PhysDoc            : IDocument;   // Doc's compiled physical counterpart -- see GetPhysicalDocument
    NetLabels          : TStringList; // "X|Y|Text" rows, from BuildNetLabelList -- this sheet's own net labels
    Wires              : TStringList; // vertex-list rows, from BuildWireList -- this sheet's own wires
    LocalLabelText     : String;   // this sheet's own net-label text for the current harness entry, if any
begin
    SheetFile := ExtractFileName(SchDoc.DocumentName);

    Report.Add('');
    Report.Add('=== Sheet: ' + SheetFile + ' ===');

    HarnessPortNames := TStringList.Create;
    NetLabels        := TStringList.Create;
    Wires             := TStringList.Create;
    // Net/connectivity data only lives on the compiled PHYSICAL document --
    // see GetPhysicalDocument.
    PhysDoc := GetPhysicalDocument(Doc);
    BuildNetLabelList(SchDoc, NetLabels);
    BuildWireList(SchDoc, Wires);
    try
        { ---------- 1) Ports -------------------------------------------------- }
        Report.Add('  Ports:');
        PortCount := 0;
        // SchIterator_Create returns a document-level iterator; the filter
        // restricts it to ePort objects only.
        Iterator := SchDoc.SchIterator_Create;
        try
            Iterator.AddFilter_ObjectSet(MkSet(ePort));
            Port := Iterator.FirstSchObject;
            while Port <> nil do
            begin
                PortLine := '    - ' + Port.Name;
                // A non-empty HarnessType marks a signal-harness port (AD10+ API,
                // present in Altium 23). The port "signal" is then a harness --
                // remember its name so the Harness connectors section below can
                // show which port carries each harness type on this sheet.
                if Port.HarnessType <> '' then
                begin
                    PortLine := PortLine + '   (signal-harness port, harness type: '
                                         + Port.HarnessType + ')';
                    HarnessPortNames.Add(Port.HarnessType + '|' + Port.Name);
                end;
                // Real compiled/physical net name (Net Properties panel's "Physical
                // Name"), alongside the display name above -- see ResolvePortNetName.
                // A signal-harness port carries a bundle, not a single net, so this is
                // expected to come back "(unresolved)" for those.
                NetName := ResolvePortNetName(PhysDoc, Port.Name);
                if NetName <> '' then
                    PortLine := PortLine + '   [Net: ' + NetName + ']'
                else
                    PortLine := PortLine + '   [Net: (unresolved)]';
                Report.Add(PortLine);

                Inc(PortCount);
                Port := Iterator.NextSchObject;
            end;
        finally
            // Iterators MUST be destroyed by the object that created them.
            SchDoc.SchIterator_Destroy(Iterator);
        end;
        if PortCount = 0 then Report.Add('    (none)');
        GTotalPorts := GTotalPorts + PortCount;

        { ---------- 2) Harness connectors ------------------------------------- }
        Report.Add('  Harness connectors:');
        HarnessCount := 0;
        Iterator := SchDoc.SchIterator_Create;
        try
            Iterator.AddFilter_ObjectSet(MkSet(eHarnessConnector));
            Harness := Iterator.FirstSchObject;
            while Harness <> nil do
            begin
                HarnessType := '';

                EntryList := TStringList.Create;
                try
                    // Children of a harness connector are reached through a GROUP
                    // iterator created on the connector itself, not on the document.
                    // eHarnessConnectorType holds the type label; eHarnessEntry
                    // objects are the individual signals of the harness.
                    GroupIterator := Harness.SchIterator_Create;
                    try
                        GroupIterator.AddFilter_ObjectSet(
                            MkSet(eHarnessEntry, eHarnessConnectorType));
                        Child := GroupIterator.FirstSchObject;
                        while Child <> nil do
                        begin
                            if Child.ObjectId = eHarnessConnectorType then
                                HarnessType := Child.Text            // type label
                            else if Child.ObjectId = eHarnessEntry then
                            begin
                                // Resolve this entry's physical net by ITS OWN location
                                // now, while Child is still valid -- see
                                // ResolveHarnessEntryNetName -- plus THIS SHEET's own net
                                // label, if any (see FindNetLabelAtOrNearPoint). Carried
                                // alongside the entry name as a pipe row; the write-out
                                // loop below (after HarnessType is known) just reads it
                                // back.
                                LocalLabelText := FindNetLabelAtOrNearPoint(
                                    NetLabels, Wires, Child.Location.X, Child.Location.Y);
                                EntryList.Add(Child.Name + '|' +
                                    ResolveHarnessEntryNetName(PhysDoc, Child.Location.X, Child.Location.Y) +
                                    '|' + LocalLabelText);
                            end;
                            Child := GroupIterator.NextSchObject;
                        end;
                    finally
                        Harness.SchIterator_Destroy(GroupIterator);
                    end;

                    if HarnessType = '' then HarnessType := '<unnamed type>';
                    // Show the signal-harness port that carries this harness on
                    // this sheet (matched by HarnessType, collected in Section 1
                    // above), then each signal on its own line as
                    // "<Net Name>   [Net: <Physical Name>]" (see the write-out loop
                    // below for what "Net Name" means here).
                    PortNameForHarness := FindPortNameForHarnessType(HarnessPortNames, HarnessType);
                    if PortNameForHarness <> '' then
                        QualifiedPrefix := PortNameForHarness
                    else
                        QualifiedPrefix := HarnessType; // no matching port -- fall back to the harness type itself
                    if PortNameForHarness = '' then PortNameForHarness := '<no matching port>';
                    Report.Add('    - ' + PortNameForHarness + ' (Type ' + HarnessType + ')');
                    if EntryList.Count = 0 then
                        Report.Add('        (no entries)')
                    else
                        for k := 0 to EntryList.Count - 1 do
                        begin
                            // EntryList rows are "EntryName|PhysicalNetName|LocalLabelText"
                            // (either of the last two fields may be empty), resolved while
                            // the eHarnessEntry object was still valid -- see the
                            // collection loop above.
                            //
                            // The displayed name is THIS SHEET's own "Net Name": if a real
                            // net label is placed on this entry ON THIS SHEET (LocalLabelText,
                            // from FindNetLabelAtOrNearPoint), that label's own text IS the
                            // Net Name here -- matching what Altium's Net Properties panel
                            // would show for this sheet. Otherwise it falls back to the
                            // synthesized "<PortName>.<EntryName>" form, Altium's own
                            // auto-generated Net Name when no local label exists. Either
                            // way, [Net: ...] is the separate, final merged/flattened
                            // "Physical Name" -- the same electrical net across every sheet,
                            // e.g. "CAN0_RX" once a custom label anywhere in the design
                            // overrides the auto name -- so the two can legitimately differ
                            // per sheet even though they're the same net.
                            LocalLabelText := GetPipeField(EntryList[k], 2);
                            if LocalLabelText <> '' then
                                QualifiedName := LocalLabelText
                            else
                                QualifiedName := QualifiedPrefix + '.' + GetPipeField(EntryList[k], 0);
                            NetName := GetPipeField(EntryList[k], 1);
                            if NetName <> '' then
                                Report.Add('        ' + QualifiedName + '   [Net: ' + NetName + ']')
                            else
                                Report.Add('        ' + QualifiedName + '   [Net: (unresolved)]');
                        end;
                finally
                    EntryList.Free;
                end;

                Inc(HarnessCount);
                Harness := Iterator.NextSchObject;
            end;
        finally
            SchDoc.SchIterator_Destroy(Iterator);
        end;
        if HarnessCount = 0 then Report.Add('    (none)');
        GTotalHarnesses := GTotalHarnesses + HarnessCount;
    finally
        HarnessPortNames.Free;
        NetLabels.Free;
        Wires.Free;
    end;

    Inc(GTotalSheets);
end;

{..............................................................................}
{ Entry point - run this procedure from DXP > Run Script.                      }
{..............................................................................}
procedure ExtractPortAndHarnessSignals;
var
    WS           : IWorkspace;
    Project      : IProject;
    Doc          : IDocument;
    SchDoc       : ISch_Document;
    ServerDoc    : IServerDocument;
    ReportDoc    : IServerDocument;
    Report       : TStringList;
    ReportFolder : String;
    ReportPath   : String;
    i            : Integer;
    CompileOK    : Boolean;
begin
    GTotalSheets    := 0;
    GTotalPorts     := 0;
    GTotalHarnesses := 0;

    // IWorkspace gives access to the project/document management (DM_) API.
    WS := GetWorkspace;
    if WS = nil then
    begin
        ShowMessage('Cannot access the workspace.');
        Exit;
    end;

    Project := WS.DM_FocusedProject;
    if Project = nil then
    begin
        ShowMessage('No focused project. Open/focus a PCB project first.');
        Exit;
    end;

    // Make sure the schematic editor server is loaded, otherwise SchServer
    // can be nil when no schematic has ever been opened in this session.
    Client.StartServer('SCH');
    if SchServer = nil then
    begin
        ShowMessage('Schematic server (SCH) could not be started.');
        Exit;
    end;

    // Compile the project ONCE, up front, so every sheet's net-resolution calls
    // below can read real compiled/physical net names. Wrapped in try/except
    // since DM_Compile's exact failure behavior (exception vs. False result)
    // isn't verified in this environment; either way we degrade to
    // "(unresolved)" net names per-object rather than aborting the whole report.
    CompileOK := False;
    try
        CompileOK := Project.DM_Compile;
    except
        CompileOK := False;
    end;

    Report := TStringList.Create;
    try
        Report.Add('Port & Harness Signal Report');
        Report.Add('Project : ' + Project.DM_ProjectFullPath);
        Report.Add('Date    : ' + DateTimeToStr(Now));
        if not CompileOK then
            Report.Add('WARNING : Project.DM_Compile did not report success -- '
                      + 'physical net names below may all show as (unresolved).');
        Report.Add(StringOfChar('-', 70));

        // DM_LogicalDocuments enumerates all documents added to the project;
        // DM_DocumentKind identifies schematics as 'SCH'.
        for i := 0 to Project.DM_LogicalDocumentCount - 1 do
        begin
            Doc := Project.DM_LogicalDocuments(i);
            if UpperCase(Doc.DM_DocumentKind) <> 'SCH' then Continue;

            // Open the document server-side (loads it into memory without
            // forcing it into view) so the SCH object model is populated.
            ServerDoc := Client.OpenDocument('SCH', Doc.DM_FullPath);
            if ServerDoc = nil then
            begin
                Report.Add('');
                Report.Add('=== Sheet: ' + Doc.DM_FileName +
                           ' ===  ** could not be opened, skipped **');
                Continue;
            end;

            // Fetch the ISch_Document interface for the now-loaded sheet.
            SchDoc := SchServer.GetSchDocumentByPath(Doc.DM_FullPath);
            if SchDoc = nil then
            begin
                Report.Add('');
                Report.Add('=== Sheet: ' + Doc.DM_FileName +
                           ' ===  ** no SCH interface, skipped **');
                Continue;
            end;

            ProcessSchematicSheet(SchDoc, Doc, Report);
        end;

        Report.Add('');
        Report.Add(StringOfChar('-', 70));
        Report.Add('Sheets processed    : ' + IntToStr(GTotalSheets));
        Report.Add('Ports found         : ' + IntToStr(GTotalPorts));
        Report.Add('Harness connectors  : ' + IntToStr(GTotalHarnesses));

        // Save the report next to this script's own project (.PrjScr), not
        // necessarily next to the focused design project -- fall back to the
        // focused project's folder only if the script's own project can't be
        // located (e.g. it was removed from the workspace after starting).
        ReportFolder := GetScriptProjectFolder(WS);
        if ReportFolder = '' then
            ReportFolder := ExtractFilePath(Project.DM_ProjectFullPath);
        ReportPath := ReportFolder + 'PortHarnessSignals.txt';
        Report.SaveToFile(ReportPath);
    finally
        Report.Free;
    end;

    // Open and show the report inside Altium's text editor.
    ReportDoc := Client.OpenDocument('Text', ReportPath);
    if ReportDoc <> nil then
        Client.ShowDocument(ReportDoc);

    // Single summary dialog at the very end (no mid-script popups).
    ShowMessage('Done.' + #13#10 +
                'Sheets processed: '   + IntToStr(GTotalSheets)    + #13#10 +
                'Ports found: '        + IntToStr(GTotalPorts)     + #13#10 +
                'Harness connectors: ' + IntToStr(GTotalHarnesses) + #13#10 +
                'Report: ' + ReportPath);
end;
