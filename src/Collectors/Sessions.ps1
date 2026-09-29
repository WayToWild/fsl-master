# FSL Master - user sessions. Primary source: WTS API (object based, locale independent).
# Fallback: quser.exe text parsing (also used for tests).

function Initialize-FslWtsType {
    if ('FslWts' -as [type]) { return $true }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class FslWts
{
    [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool WTSEnumerateSessions(IntPtr hServer, int reserved, int version, out IntPtr ppSessionInfo, out int pCount);
    [DllImport("wtsapi32.dll")]
    static extern void WTSFreeMemory(IntPtr p);
    [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool WTSQuerySessionInformation(IntPtr hServer, int sessionId, int infoClass, out IntPtr buffer, out int bytes);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WTS_SESSION_INFO { public int SessionId; public IntPtr pWinStationName; public int State; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WTSINFO
    {
        public int State; public int SessionId; public int IncomingBytes; public int OutgoingBytes;
        public int IncomingFrames; public int OutgoingFrames; public int IncomingCompressedBytes; public int OutgoingCompressedBytes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string WinStationName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 17)] public string Domain;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 21)] public string UserName;
        public long ConnectTime; public long DisconnectTime; public long LastInputTime; public long LogonTime; public long CurrentTime;
    }

    public class Row
    {
        public int SessionId; public string WinStation; public int State; public string User; public string Domain;
        public DateTime? LogonTime; public DateTime? LastInput; public DateTime? Now; public string Client;
    }

    static string QueryString(int session, int cls)
    {
        IntPtr buf; int bytes;
        if (!WTSQuerySessionInformation(IntPtr.Zero, session, cls, out buf, out bytes)) return "";
        try { return Marshal.PtrToStringUni(buf) ?? ""; } finally { WTSFreeMemory(buf); }
    }

    static DateTime? FromFt(long ft)
    {
        if (ft <= 0) return null;
        try { return DateTime.FromFileTime(ft); } catch { return null; }
    }

    public static Row[] Enumerate()
    {
        IntPtr p; int count;
        var list = new List<Row>();
        if (!WTSEnumerateSessions(IntPtr.Zero, 0, 1, out p, out count)) return list.ToArray();
        try
        {
            int size = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
            for (int i = 0; i < count; i++)
            {
                var si = (WTS_SESSION_INFO)Marshal.PtrToStructure(new IntPtr(p.ToInt64() + (long)i * size), typeof(WTS_SESSION_INFO));
                var r = new Row();
                r.SessionId = si.SessionId;
                r.WinStation = si.pWinStationName == IntPtr.Zero ? "" : Marshal.PtrToStringUni(si.pWinStationName);
                r.State = si.State;
                r.User = QueryString(si.SessionId, 5);
                r.Domain = QueryString(si.SessionId, 7);
                r.Client = QueryString(si.SessionId, 10);
                IntPtr buf; int bytes;
                if (WTSQuerySessionInformation(IntPtr.Zero, si.SessionId, 24, out buf, out bytes))
                {
                    try
                    {
                        var info = (WTSINFO)Marshal.PtrToStructure(buf, typeof(WTSINFO));
                        r.LogonTime = FromFt(info.LogonTime);
                        r.LastInput = FromFt(info.LastInputTime);
                        r.Now = FromFt(info.CurrentTime);
                    }
                    finally { WTSFreeMemory(buf); }
                }
                list.Add(r);
            }
        }
        finally { WTSFreeMemory(p); }
        return list.ToArray();
    }
}
'@
        return $true
    } catch { return $false }
}

function Get-FslWtsStateName {
    param([int]$State)
    switch ($State) {
        0 { 'Active' } 1 { 'Connected' } 2 { 'ConnectQuery' } 3 { 'Shadow' } 4 { 'Disconnected' }
        5 { 'Idle' } 6 { 'Listen' } 7 { 'Reset' } 8 { 'Down' } 9 { 'Init' } default { 'Unknown' }
    }
}

function ConvertFrom-FslQuserOutput {
    # Locale-tolerant parser for quser.exe output. Header text is ignored; rows are recognised by the numeric session ID.
    param([string[]]$Lines)
    foreach ($line in @($Lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $l = $line.TrimEnd()
        $isCurrent = $l.TrimStart().StartsWith('>')
        $l = $l -replace '^\s*>?', ''
        $m = $null
        # with session name: user sessionname id state idle logon...
        if ($l -match '^(\S+)\s+(\S+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(.+)$') {
            $m = @{ User = $Matches[1]; Session = $Matches[2]; Id = [int]$Matches[3]; State = $Matches[4]; Idle = $Matches[5]; Logon = $Matches[6] }
        } elseif ($l -match '^(\S+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(.+)$') {   # disconnected: no session name
            $m = @{ User = $Matches[1]; Session = ''; Id = [int]$Matches[2]; State = $Matches[3]; Idle = $Matches[4]; Logon = $Matches[5] }
        }
        if (-not $m) { continue }
        $logon = $null; $dt = [datetime]::MinValue
        if ([datetime]::TryParse($m.Logon, [ref]$dt) -or [datetime]::TryParse($m.Logon, [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$dt)) { $logon = $dt }
        $idle = $null
        if ($m.Idle -match '^(?:(\d+)\+)?(?:(\d+):)?(\d+)$') {
            $d = if ($Matches[1]) { [int]$Matches[1] } else { 0 }
            $h = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
            $idle = New-TimeSpan -Days $d -Hours $h -Minutes ([int]$Matches[3])
        } elseif ($m.Idle -match '^\d+$') { $idle = New-TimeSpan -Minutes ([int]$m.Idle) }
        [pscustomobject]@{ User = $m.User; WinStation = $m.Session; SessionId = $m.Id; State = $m.State; Idle = $idle; LogonTime = $logon; IsCurrent = $isCurrent }
    }
}

function Get-FslSidForAccount {
    param([string]$Domain, [string]$User)
    try {
        $nt = if ($Domain) { New-Object Security.Principal.NTAccount($Domain, $User) } else { New-Object Security.Principal.NTAccount($User) }
        return $nt.Translate([Security.Principal.SecurityIdentifier]).Value
    } catch { return $null }
}

function Get-FslAccountForSid {
    param([string]$Sid)
    try { return (New-Object Security.Principal.SecurityIdentifier($Sid)).Translate([Security.Principal.NTAccount]).Value } catch { return $null }
}

function Get-FslRawSessions {
    # Returns objects: User, Domain, SessionId, State, StateKey, LogonTime, Idle, WinStation, Client, Source
    $out = @()
    if (Initialize-FslWtsType) {
        try {
            foreach ($r in [FslWts]::Enumerate()) {
                if ([string]::IsNullOrEmpty($r.User)) { continue }
                $idle = $null
                if ($r.LastInput -and $r.Now -and $r.Now -ge $r.LastInput) { $idle = $r.Now - $r.LastInput }
                $out += [pscustomobject]@{
                    User = $r.User; Domain = $r.Domain; SessionId = $r.SessionId; State = (Get-FslWtsStateName $r.State); StateKey = (Get-FslWtsStateName $r.State)
                    LogonTime = $r.LogonTime; Idle = $idle; WinStation = $r.WinStation; Client = $r.Client; Source = 'WTS API'
                }
            }
            return $out
        } catch { $out = @() }
    }
    try {
        $lines = & quser.exe 2>$null
        foreach ($q in (ConvertFrom-FslQuserOutput -Lines $lines)) {
            $out += [pscustomobject]@{
                User = $q.User; Domain = $env:COMPUTERNAME; SessionId = $q.SessionId; State = $q.State; StateKey = $q.State
                LogonTime = $q.LogonTime; Idle = $q.Idle; WinStation = $q.WinStation; Client = ''; Source = 'quser.exe'
            }
        }
    } catch { }
    $out
}

function Get-FslUserProfiles {
    # Win32_UserProfile + ProfileList registry, keyed by SID.
    $map = @{}
    try {
        Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop | Where-Object { -not $_.Special } | ForEach-Object {
            $map[$_.SID] = [pscustomobject]@{ Sid = $_.SID; LocalPath = $_.LocalPath; Loaded = [bool]$_.Loaded; Status = [int]$_.Status; LastUse = $_.LastUseTime }
        }
    } catch { }
    foreach ($sid in (Get-FslRegistrySubKeyNames 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList')) {
        if ($map.ContainsKey($sid)) { continue }
        $p = Get-FslRegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -Name 'ProfileImagePath'
        if ($p) { $map[$sid] = [pscustomobject]@{ Sid = $sid; LocalPath = "$($p.Value)"; Loaded = $null; Status = 0; LastUse = $null } }
    }
    $map
}

function Get-FslSessions {
    $profiles = Get-FslUserProfiles
    $raw = @(Get-FslRawSessions)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($s in $raw) {
        $sid = Get-FslSidForAccount -Domain $s.Domain -User $s.User
        $prof = if ($sid -and $profiles.ContainsKey($sid)) { $profiles[$sid] } else { $null }
        $logon = $s.LogonTime
        if (-not $logon) {
            try { $logon = (Get-Process -IncludeUserName:$false -ErrorAction Stop | Where-Object { $_.SessionId -eq $s.SessionId -and $_.StartTime } | Sort-Object StartTime | Select-Object -First 1).StartTime } catch { }
        }
        $profNote = ''
        $status = 'OK'
        if ($prof) {
            if ($prof.Status -band 1) { $profNote = 'Tijdelijk profiel'; $status = 'Error' }
            elseif ($prof.Status -band 8) { $profNote = 'Beschadigd profiel'; $status = 'Error' }
            if ($prof.LocalPath -match '\.bak$|\\TEMP(\.|$)') { $profNote = 'Mogelijk tijdelijk profiel (pad)'; $status = 'Warning' }
        } else { $profNote = 'Profiel niet gevonden'; $status = 'Unknown' }
        $rows.Add([pscustomobject]@{
            User = $s.User; Domain = $s.Domain; Sid = $sid; SessionId = $s.SessionId; State = $s.State
            LogonTime = $logon; Idle = $s.Idle; IdleText = $(if ($s.Idle) { Format-FslTimeSpan $s.Idle } else { '' })
            Client = $s.Client; WinStation = $s.WinStation
            ProfilePath = $(if ($prof) { $prof.LocalPath } else { '' }); ProfileLoaded = $(if ($prof -and $null -ne $prof.Loaded) { $(if ($prof.Loaded) { 'Ja' } else { 'Nee' }) } else { '' })
            ProfileNote = $profNote
            ContainerMounted = 'Onbekend'; ContainerType = ''; ContainerPath = ''; VhdFile = ''; ContainerStatus = ''
            Status = $status; StatusText = (Get-FslStatusText $status); Glyph = (Get-FslStatusGlyph $status); Source = $s.Source
        })
    }
    $rows.ToArray()
}

function Merge-FslSessionContainers {
    # Adds container info to sessions. Mounted = Ja / Nee / Onbekend.
    param($Sessions, $Containers, [bool]$FslogixInstalled, [bool]$ProfilesEnabled, [bool]$ContainerDataAvailable)
    foreach ($s in @($Sessions)) {
        $match = @()
        if ($Containers) { $match = @($Containers | Where-Object { ($s.Sid -and $_.Sid -eq $s.Sid) -or ($_.User -and $s.User -and ($_.User -split '\\')[-1] -ieq $s.User) }) }
        if ($match.Count -gt 0) {
            $s.ContainerMounted = 'Ja'
            $s.ContainerType = (($match | ForEach-Object { $_.RedirectType } | Where-Object { $_ } | Select-Object -Unique) -join ', ')
            $s.ContainerPath = (($match | ForEach-Object { $_.ContainerPath } | Where-Object { $_ } | Select-Object -Unique) -join '; ')
            $s.VhdFile = (($match | ForEach-Object { $_.VhdFile } | Where-Object { $_ } | Select-Object -Unique) -join '; ')
            $worst = 'OK'
            foreach ($m in $match) { if ($m.Status -eq 'Error') { $worst = 'Error' } elseif ($m.Status -eq 'Warning' -and $worst -ne 'Error') { $worst = 'Warning' } elseif ($m.Status -eq 'Unknown' -and $worst -eq 'OK') { $worst = 'Unknown' } }
            $s.ContainerStatus = Get-FslStatusText $worst
            if ($worst -eq 'Error' -and $s.Status -ne 'Error') { $s.Status = 'Error' } elseif ($worst -eq 'Warning' -and $s.Status -eq 'OK') { $s.Status = 'Warning' }
        } elseif ($FslogixInstalled -and $ProfilesEnabled -and $ContainerDataAvailable) {
            $s.ContainerMounted = 'Nee'; $s.ContainerStatus = 'Geen container gevonden'
            if ($s.Status -eq 'OK') { $s.Status = 'Warning' }
        } else {
            $s.ContainerMounted = 'Onbekend'
            $s.ContainerStatus = if (-not $FslogixInstalled) { 'FSLogix niet geïnstalleerd' } elseif (-not $ProfilesEnabled) { 'Profile Containers niet ingeschakeld' } else { 'Geen containergegevens' }
        }
        $s.StatusText = Get-FslStatusText $s.Status
        $s.Glyph = Get-FslStatusGlyph $s.Status
    }
    $Sessions
}
