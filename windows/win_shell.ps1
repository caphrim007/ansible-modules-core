#!powershell
# This file is part of Ansible
#
# Ansible is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Ansible is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Ansible.  If not, see <http://www.gnu.org/licenses/>.

# WANT_JSON
# POWERSHELL_COMMON

# TODO: add check mode support

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

$parsed_args = Parse-Args $args $false

$raw_command_line = $(Get-AnsibleParam $parsed_args "_raw_params" -failifempty $true).Trim()
$chdir = Get-AnsibleParam $parsed_args "chdir"
$executable = Get-AnsibleParam $parsed_args "executable"
$creates = Get-AnsibleParam $parsed_args "creates"
$removes = Get-AnsibleParam $parsed_args "removes"

$result = @{changed=$true; warnings=@(); cmd=$raw_command_line}

If($creates -and $(Test-Path $creates)) {
    Exit-Json @{cmd=$raw_command_line; msg="skipped, since $creates exists"; changed=$false; skipped=$true; rc=0}
}

If($removes -and -not $(Test-Path $removes)) {
    Exit-Json @{cmd=$raw_command_line; msg="skipped, since $removes does not exist"; changed=$false; skipped=$true; rc=0}
}

$exec_args = $null

If(-not $executable -or $executable -eq "powershell") {
    $exec_application = "powershell"

    # Base64 encode the command so we don't have to worry about the various levels of escaping
    $encoded_command = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($raw_command_line))

    $exec_args = @("-noninteractive", "-encodedcommand", $encoded_command)
}
Else {
    # FUTURE: support arg translation from executable (or executable_args?) to process arguments for arbitrary interpreter?
    $exec_application = $executable
    $exec_args = @("/c", $raw_command_line)
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exec_application
$psi.Arguments = $exec_args
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true

If ($chdir) {
    $psi.WorkingDirectory = $chdir
}

$proc = New-Object -TypeName System.Diagnostics.Process
$proc.StartInfo = $psi

# Creating string builders to store stdout and stderr
$oStdOutBuilder = New-Object -TypeName System.Text.StringBuilder
$oStdErrBuilder = New-Object -TypeName System.Text.StringBuilder

# Adding event handlers for stdout and stderr
$sScriptBlock = {
    if (! [String]::IsNullOrEmpty($EventArgs.Data)) {
        $Event.MessageData.AppendLine($EventArgs.Data)
    }
}
$oStdOutEvent = Register-ObjectEvent -InputObject $proc `
    -Action $sScriptBlock -EventName 'OutputDataReceived' `
    -MessageData $oStdOutBuilder
$oStdErrEvent = Register-ObjectEvent -InputObject $proc `
    -Action $sScriptBlock -EventName 'ErrorDataReceived' `
    -MessageData $oStdErrBuilder

$start_datetime = [DateTime]::UtcNow

Try {
    [Void]$proc.Start() # will always return $true for non shell-exec cases
}
Catch [System.ComponentModel.Win32Exception] {
    # fail nicely for "normal" error conditions
    # FUTURE: this probably won't work on Nano Server
    $excep = $_
    Exit-Json @{failed=$true;changed=$false;cmd=$raw_command_line;rc=$excep.Exception.NativeErrorCode;msg=$excep.Exception.Message}
}

$proc.BeginOutputReadLine()
$proc.BeginErrorReadLine()
[Void]$proc.WaitForExit()

# Unregistering events to retrieve process output
Unregister-Event -SourceIdentifier $oStdOutEvent.Name
Unregister-Event -SourceIdentifier $oStdErrEvent.Name

$oResult = New-Object -TypeName PSObject -Property ([Ordered]@{
    "ExeFile" = $exec_application;
    "Args" = $exec_args;
    "ExitCode" = $proc.ExitCode;
    "StdOut" = $oStdOutBuilder.ToString().Trim();
    "StdErr" = $oStdErrBuilder.ToString().Trim()
})

$result.rc = $oResult.ExitCode

$end_datetime = [DateTime]::UtcNow

$result.stderr = $oResult.StdErr
$result.stdout = $oResult.StdOut
$result.start = $start_datetime.ToString("yyyy-MM-dd hh:mm:ss.ffffff")
$result.end = $end_datetime.ToString("yyyy-MM-dd hh:mm:ss.ffffff")
$result.delta = $($end_datetime - $start_datetime).ToString("h\:mm\:ss\.ffffff")

ConvertTo-Json -Depth 99 $result
