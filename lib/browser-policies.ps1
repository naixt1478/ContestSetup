# lib/browser-policies.ps1
# Canonical HKLM Browser DoH & AI/Copilot policy specifications shared across apply and restore flows

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { $global:PSNativeCommandUseErrorActionPreference = $false } catch {}

function Get-BrowserPolicySpecifications
{
  return @(
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'DnsOverHttpsMode'; Type = 'String'; Value = 'off' },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'BuiltInDnsClientEnabled'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'DnsOverHttpsMode'; Type = 'String'; Value = 'off' },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'BuiltInDnsClientEnabled'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'HubsSidebarEnabled'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'CopilotPageContext'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; Name = 'DnsOverHttpsMode'; Type = 'String'; Value = 'off' },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; Name = 'BuiltInDnsClientEnabled'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Naver\Naver Whale'; Name = 'DnsOverHttpsMode'; Type = 'String'; Value = 'off' },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Naver\Naver Whale'; Name = 'BuiltInDnsClientEnabled'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS'; Name = 'Enabled'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS'; Name = 'Locked'; Type = 'DWord'; Value = 1 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Type = 'DWord'; Value = 1 }
  )
}

function Get-ExtendedBrowserPolicySpecifications
{
  return @(
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'DnsOverHttpsTemplates'; Type = 'String'; Value = '' },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'BuiltInAIAPIsEnabled'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'GenAILocalFoundationalModelSettings'; Type = 'DWord'; Value = 1 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'DnsOverHttpsTemplates'; Type = 'String'; Value = '' },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'EdgeEntraCopilotPageContext'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'BuiltInAIAPIsEnabled'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; Name = 'DnsOverHttpsTemplates'; Type = 'String'; Value = '' },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; Name = 'BraveAIChatEnabled'; Type = 'DWord'; Value = 0 },
    @{ KeyPath = 'HKLM:\SOFTWARE\Policies\Naver\Naver Whale'; Name = 'DnsOverHttpsTemplates'; Type = 'String'; Value = '' }
  )
}
