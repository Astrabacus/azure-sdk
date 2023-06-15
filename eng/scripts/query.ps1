[CmdletBinding()]
param (
  [string] $github_pat = $env:GITHUB_PAT
)
# Set-StrictMode -Version 3

. (Join-Path $PSScriptRoot PackageList-Helpers.ps1)

function Get-android-Packages
{
  # Rest API docs https://search.maven.org/classic/#api
  $baseMavenQueryUrl = "https://search.maven.org/solrsearch/select?q=g:com.azure.android&rows=100&wt=json"
  $mavenQuery = Invoke-RestMethod "https://search.maven.org/solrsearch/select?q=g:com.azure.android&rows=2000&wt=json" -MaximumRetryCount 3

  Write-Host "Found $($mavenQuery.response.numFound) android packages on maven packages"

  $packages = @()
  $count = 0
  while ($count -lt $mavenQuery.response.numFound)
  {
    $packages += $mavenQuery.response.docs | Foreach-Object { CreatePackage $_.a $_.latestVersion $_.g }
    $count += $mavenQuery.response.docs.count

    $mavenQuery = Invoke-RestMethod ($baseMavenQueryUrl + "&start=$count") -MaximumRetryCount 3
  }

  return $packages
}

function Get-java-Packages
{
  # Rest API docs https://search.maven.org/classic/#api
  $baseMavenQueryUrl = "https://search.maven.org/solrsearch/select?q=g:com.microsoft.azure*%20OR%20g:com.azure*&rows=100&wt=json"
  $mavenQuery = Invoke-RestMethod $baseMavenQueryUrl -MaximumRetryCount 3

  Write-Host "Found $($mavenQuery.response.numFound) java packages on maven packages"

  $packages = @()
  $count = 0
  while ($count -lt $mavenQuery.response.numFound)
  {
    $packages += $mavenQuery.response.docs | Foreach-Object { if ($_.g -ne "com.azure.android") { CreatePackage $_.a $_.latestVersion $_.g } }
    $count += $mavenQuery.response.docs.count

    $mavenQuery = Invoke-RestMethod ($baseMavenQueryUrl + "&start=$count") -MaximumRetryCount 3
  }

  $repoTags = GetPackageVersions "java"

  foreach ($package in $packages)
  {
    # If package is in com.azure.resourcemanager groupid and we shipped it recently because it is in the last months repo tags
    # then treat it as a new mgmt library
    if ($package.GroupId -eq "com.azure.resourcemanager" `
        -and $package.Package -match "^azure-resourcemanager-(?<serviceName>.*?)$" `
        -and $repoTags.ContainsKey($package.Package))
    {
      $serviceName = (Get-Culture).TextInfo.ToTitleCase($matches["serviceName"])
      $package.Type = "mgmt"
      $package.New = "true"
      $package.RepoPath = $matches["serviceName"].ToLower()
      $package.ServiceName = $serviceName
      $package.DisplayName = "Resource Management - $serviceName"
      Write-Verbose "Marked package $($package.Package) as new mgmt package with version $($package.VersionGA + $package.VersionPreview)"
    }
  }

  return $packages
}

function Get-dotnet-Packages
{
  # Rest API docs
  # https://docs.microsoft.com/nuget/api/search-query-service-resource
  # https://docs.microsoft.com/nuget/consume-packages/finding-and-choosing-packages#search-syntax
  $nugetQuery = Invoke-RestMethod "https://azuresearch-usnc.nuget.org/query?q=owner:azure-sdk&prerelease=true&semVerLevel=2.0.0&take=1000" -MaximumRetryCount 3

  Write-Host "Found $($nugetQuery.totalHits) nuget packages"
  $packages = $nugetQuery.data | Foreach-Object { CreatePackage $_.id $_.version }

  $repoTags = GetPackageVersions "dotnet"

  foreach ($package in $packages)
  {
    # If package starts with Azure.ResourceManager. and we shipped it recently because it is in the last months repo tags
    # then treat it as a new mgmt library
    if ($package.Package -match "^Azure.ResourceManager.(?<serviceName>.*?)$" -and $repoTags.ContainsKey($package.Package))
    {
      $serviceName = (Get-Culture).TextInfo.ToTitleCase($matches["serviceName"])
      $package.Type = "mgmt"
      $package.New = "true"
      $package.RepoPath = $matches["serviceName"].ToLower()
      $package.ServiceName = $serviceName
      $package.DisplayName = "Resource Management - $serviceName"
      Write-Verbose "Marked package $($package.Package) as new mgmt package with version $($package.VersionGA + $package.VersionPreview)"
    }
  }

  return $packages
}

function Get-js-Packages
{
  $from = 0
  $npmPackages = @()

  do
  {
    # Rest API docs https://github.com/npm/registry/blob/master/docs/REGISTRY-API.md
    # max size returned is 250 so we have to do some basic paging.
    $npmQuery = Invoke-RestMethod "https://registry.npmjs.com/-/v1/search?text=maintainer:azure-sdk&size=250&from=$from" -MaximumRetryCount 3

    if ($npmQuery.objects.Count -ne 0) {
      $npmPackages += $npmQuery.objects.package
    }
    $from += $npmQuery.objects.Count
  } while ($npmQuery.objects.Count -ne 0);

  $publishedPackages = $npmPackages | Where-Object { $_.publisher.username -eq "azure-sdk" }
  $otherPackages = $npmPackages | Where-Object { $_.publisher.username -ne "azure-sdk" }

  foreach ($otherPackage in $otherPackages) {
    Write-Verbose "Not updating package $($otherPackage.name) because the publisher is $($otherPackage.publisher.username) and not azure-sdk"
  }

  Write-Host "Found $($publishedPackages.Count) npm packages"
  $packages = $publishedPackages | Foreach-Object { CreatePackage $_.name $_.version }

  $repoTags = GetPackageVersions "js"

  foreach ($package in $packages)
  {
    # If package starts with arm- and we shipped it recently because it is in the last months repo tags
    # then treat it as a new mgmt library
    if ($package.Package -match "^@azure/arm-(?<serviceName>.*?)(-profile.*)?$" -and $repoTags.ContainsKey($package.Package))
    {
      $serviceName = (Get-Culture).TextInfo.ToTitleCase($matches["serviceName"])
      $package.Type = "mgmt"
      $package.New = "true"
      $package.RepoPath = $matches["serviceName"].ToLower()
      $package.ServiceName = $serviceName
      $package.DisplayName = "Resource Management - $serviceName"
      Write-Verbose "Marked package $($package.Package) as new mgmt package with version $($package.VersionGA + $package.VersionPreview)"
    }
  }

  return $packages
}

function Get-python-Packages
{
  $pythonQuery = "import xmlrpc.client; [print(pkg[1]) for pkg in xmlrpc.client.ServerProxy('https://pypi.org/pypi').user_packages('azure-sdk')]"
  $pythonPackagesNames = (python -c "$pythonQuery")

  $pythonPackages = $pythonPackagesNames | Foreach-Object { try { (Invoke-RestMethod "https://pypi.org/pypi/$_/json" -MaximumRetryCount 3) } catch { } }
  Write-Host "Found $($pythonPackages.Count) python packages"

  $releasesWithDate = @()
  foreach ($package in $pythonPackages)
  {
    if ($package.info.name -notlike "azure-*") { Write-Host "Skipping $($package.info.name)"; continue }

    $packageVersion = $package.info.Version
    # $packageReleases = ,($package.releases.PSObject.Properties | % { @($package.info.name, $_.Name, $_.Value.upload_time?[0]) })
    $packageReleases = @()
    foreach ($prop in $package.releases.PSObject.Properties)
    {
      $packageReleases += ,(@($package.info.name, $prop.Name, $prop.Value.upload_time?[0]))
    }
    foreach ($pr in $packageReleases)
    {
      $releasesWithDate += ,($pr)
    }
    # $item = $package.releases.PSObject.Properties | % { @($package.info.name, $_.Name, $_.Value) }
    # $releasesWithDate += $package.releases.PSObject.Properties | % { @($package.info.name, $_.Name, $_.Value) }
  }

  return $releasesWithDate
}

function Get-python-Package-Buckets
{
    $packages = Get-python-Packages
    $recentPackages = $packages | ? { $_[2] -ge (Get-Date).AddYears(-2) }
    $monthHash = @{}
    foreach ($pkg in $recentPackages)
    {
        $month = Get-Date $pkg[2] -Format "yyyy-MM"
        $monthHash[$month] = $monthHash[$month] + 1
    }

    return $monthHash
}

function Get-cpp-Packages
{
  $packages = @()
  $repoTags = GetPackageVersions "cpp"

  Write-Host "Found $($repoTags.Count) recent tags in cpp repo"

  foreach ($tag in $repoTags.Keys)
  {
    $versions = [AzureEngSemanticVersion]::SortVersions($repoTags[$tag].Versions)
    $packages += CreatePackage $tag $versions[0]
  }

  return $packages
}

function Get-go-Packages
{
  $packages = @()
  $repoTags = GetPackageVersions "go"

  Write-Host "Found $($repoTags.Count) recent tags in go repo"

  foreach ($tag in $repoTags.Keys)
  {
    $versions = [AzureEngSemanticVersion]::SortVersions($repoTags[$tag].Versions)

    $package = CreatePackage $tag $versions[0]

    # We should keep this regex in sync with what is in the go repo at https://github.com/Azure/azure-sdk-for-go/blob/main/eng/scripts/Language-Settings.ps1#L40
    if ($package.Package -match "(?<modPath>(sdk|profile)/(?<serviceDir>(.*?(?<serviceName>[^/]+)/)?(?<modName>[^/]+$)))")
    {
      #$modPath = $matches["modPath"] Not using modPath currently here but keeping the capture group to be consistent with the go repo
      $modName = $matches["modName"]
      $serviceDir = $matches["serviceDir"]
      $serviceName = $matches["serviceName"]
      if (!$serviceName) { $serviceName = $modName }

      if ($modName.StartsWith("arm"))
      {
        # Skip arm packages that aren't in the resourcemanager service folder
        if (!$serviceDir.StartsWith("resourcemanager")) { continue }
        $package.Type = "mgmt"
        $package.New = "true"
        $modName = $modName.Substring(3); # Remove arm from front
        $package.DisplayName = "Resource Management - $((Get-Culture).TextInfo.ToTitleCase($modName))"
        Write-Verbose "Marked package $($package.Package) as new mgmt package with version $($package.VersionGA + $package.VersionPreview)"
      }
      elseif ($modName.StartsWith("az"))
      {
        $package.Type = "client"
        $package.New = "true"
        $modName = $modName.Substring(2); # Remove az from front
        $package.DisplayName = $((Get-Culture).TextInfo.ToTitleCase($modName))
      }

      $package.ServiceName = (Get-Culture).TextInfo.ToTitleCase($serviceName)
      $package.RepoPath = $serviceDir.ToLower()

      $packages += $package
    }
  }

  return $packages
}
