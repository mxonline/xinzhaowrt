Set-StrictMode -Version Latest

function ConvertTo-ArthurCanonicalGitSha {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    if (-not [regex]::IsMatch($text, '\A[0-9A-Fa-f]{40}\z', [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        return ''
    }
    return $text.ToLowerInvariant()
}
