$updateSession = New-Object -ComObject Microsoft.Update.Session
$searcher = $updateSession.CreateUpdateSearcher()
$results = $searcher.Search("IsHidden=0 and IsInstalled=0")

if ($results.Updates.Count -eq 0) {
    Write-Output "No updates available."
} else {
    $results.Updates | Select-Object Title, Description, SupportUrl, IsMandatory
}
