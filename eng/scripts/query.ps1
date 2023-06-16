[CmdletBinding()]
param (
  [string] $github_pat = $env:GITHUB_PAT,
  [array] $languages = @("java", "dotnet", "python", "js", "go", "cpp"),
  [int] $daysAgo = 30
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot PackageList-Helpers.ps1)

function Get-java-Packages
{
  # Rest API docs https://search.maven.org/classic/#api
  # $baseMavenQueryUrl = "https://search.maven.org/solrsearch/select?q=g:com.azure*&rows=100&wt=json"
  $baseMavenQueryUrl = "https://search.maven.org/solrsearch/select?q=g:com.microsoft.azure*%20OR%20g:com.azure*&rows=100&wt=json"
  $mavenQuery = Invoke-RestMethod $baseMavenQueryUrl -MaximumRetryCount 3

  Write-Host "Found $($mavenQuery.response.numFound) java packages on maven packages"

  $packages = @()
  $count = 0
  while ($count -lt $mavenQuery.response.numFound)
  {
    $responsePackages = $mavenQuery.response.docs
    foreach ($pkg in $responsePackages) {
     if ($pkg.g -ne "com.azure.android") {
        $p = CreatePackage $pkg.a $pkg.latestVersion $pkg.g
        $packages += $p
      }
    }
    $count += $mavenQuery.response.docs.count

    $mavenQuery = Invoke-RestMethod ($baseMavenQueryUrl + "&start=$count") -MaximumRetryCount 3
  }

  $allPackageVersionList = @()

  $pkgNum = 0
  foreach ($pkg in $packages) {
    if ($pkg.GroupId -like 'com.azure.spring*')
    {
      Write-Host "Skipping $($pkg.GroupId)"
      continue
    }

    $pkgNum++
    $pkgName = $pkg.Package
    $versionsMavenQueryUrl = "https://search.maven.org/solrsearch/select?q=a:${pkgName}&core=gav&rows=1000&wt=json"
    $versionsQuery = Invoke-RestMethod $versionsMavenQueryUrl -MaximumRetryCount 3

    $count = 0
    while ($count -lt $versionsQuery.response.numFound)
    {
      Write-Host "$pkgNum - $count - Getting versions for $($pkg.GroupId):$($pkg.Package)"
      $versions = $versionsQuery.response.docs
      foreach ($ver in $versions) {
        $verDate = [datetimeoffset]::FromUnixTimeMilliseconds($ver.timestamp).DateTime
        $allPackageVersionList += ,(@($pkgName, $ver.v, $verDate))
      }
      $count += $versionsQuery.response.docs.count

      $versionsQuery = Invoke-RestMethod ($versionsMavenQueryUrl + "&start=$count") -MaximumRetryCount 3
    }
  }

  return $allPackageVersionList
}

function Get-dotnet-Packages
{
  # Rest API docs
  # https://docs.microsoft.com/nuget/api/search-query-service-resource
  # https://docs.microsoft.com/nuget/consume-packages/finding-and-choosing-packages#search-syntax
  $nugetQuery = Invoke-RestMethod "https://azuresearch-usnc.nuget.org/query?q=owner:azure-sdk&prerelease=true&semVerLevel=2.0.0&take=1000" -MaximumRetryCount 3

  Write-Host "Found $($nugetQuery.totalHits) nuget packages"
  # $packages = $nugetQuery.data | Foreach-Object { CreatePackage $_.id $_.version }
  $packages = $nugetQuery.data
  $allPackageVersionList = @()

  $pkgNum = 0
  foreach ($pkg in $packages)
  {
    if ($pkg.title -notlike 'Azure.*' -and $pkg.title -notlike 'Microsoft.Azure.*')
    {
      Write-Host "Skipping $($pkg.title)"
      continue
    }
    Write-Host "$pkgNum - Getting versions for $($pkg.title)"
    $versionsQuery = Invoke-RestMethod $pkg.registration -MaximumRetryCount 3
    $versions = $versionsQuery.items
    foreach ($versionGroup in $versions)
    {
      foreach ($versionData in $versionGroup.items)
      {
        $version = ($versionData.packageContent -split '/')[5]
        $time = $versionData.catalogEntry.published
        $allPackageVersionList += ,(@($pkg.title, $version, $time))
      }
    }
    $pkgNum++
  }

  return $allPackageVersionList
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

  Write-Host "Found $($publishedPackages.Count) npm packages"

  $allPackageVersionList = @()
  $pkgNum = 0

  foreach ($pkg in $publishedPackages)
  {
    Write-Host "$pkgNum - Getting versions for $($pkg.name)"
    $versions = npm show $pkg.name time --json | ConvertFrom-Json
    $releases = $versions.PSObject.Properties | Where-Object {
      $_ -notlike "*created*" -and $_ -notlike "*modified*" -and $_ -notlike '*-dev*' -and $_ -notlike '*-alpha*'
    }
    foreach ($release in $releases)
    {
      $allPackageVersionList += ,(@($pkg.name, $release.Name, $release.Value))
    }
    $pkgNum++
  }

  return $allPackageVersionList
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
    $packageReleases = @()
    $pkgNum = 0
    foreach ($prop in $package.releases.PSObject.Properties)
    {
      $packageReleases += ,(@($package.info.name, $prop.Name, $prop.Value.upload_time?[0]))
      $pkgNum++
    }
    Write-Host "$pkgNum - $($package.info.name)"
    foreach ($pr in $packageReleases)
    {
      $releasesWithDate += ,($pr)
    }
  }

  return $releasesWithDate
}

function Get-cpp-Packages
{
  $packages = @()
  $offset = [DateTimeOffset]::UtcNow.AddMonths(-24)
  $repoTags = GetPackageVersions -lang "cpp" -afterDate $offset

  Write-Host "Found $($repoTags.Count) recent tags in cpp repo"

  foreach ($tag in $repoTags.Keys)
  {
    $versions = [AzureEngSemanticVersion]::SortVersions($repoTags[$tag].Versions)

    foreach ($versionData in $repoTags[$tag].Versions)
    {
      $allPackageVersionList += ,(@($tag, $versionData.RawVersion, (Get-Date $versionData.Date)))
    }
  }

  return $allPackageVersionList
}

function Get-go-Packages
{
  $packages = @()
  $offset = [DateTimeOffset]::UtcNow.AddMonths(-24)
  $repoTags = GetPackageVersions -lang "go" -afterDate $offset

  Write-Host "Found $($repoTags.Count) recent tags in go repo"

  $allPackageVersionList = @()
  $count = 0

  foreach ($tag in $repoTags.Keys)
  {
    $versions = [AzureEngSemanticVersion]::SortVersions($repoTags[$tag].Versions)

    $package = CreatePackage $tag $versions[0]

    # We should keep this regex in sync with what is in the go repo at https://github.com/Azure/azure-sdk-for-go/blob/main/eng/scripts/Language-Settings.ps1#L40
    if ($package.Package -match "(?<modPath>(sdk|profile)/(?<serviceDir>(.*?(?<serviceName>[^/]+)/)?(?<modName>[^/]+$)))")
    {
      foreach ($versionData in $repoTags[$tag].Versions)
      {
        $allPackageVersionList += ,(@($tag, $versionData.RawVersion, (Get-Date $versionData.Date)))
      }
    }
  }

  return $allPackageVersionList
}

function Get-Package-Buckets($languages, $daysAgo)
{
  $today = Get-Date
  $dayHash = @{}
  $datePos = 0
  while ($datePos -ge -$daysAgo)
  {
    # Zero value all dates so data explorer queries and charts are easier to normalize
    $day = Get-Date $today.AddDays($datePos) -Format "yyyy-MM-dd"
    $dayHash[$day] = @{}
    foreach ($lang in $languages)
    {
      $dayHash[$day][$lang] = 0
    }
    $datePos--
  }

  foreach ($lang in $languages)
  {
    $total = 0
    $packages = Invoke-Expression Get-$lang-Packages
    $recentPackages = $packages | ? { $_[2] -ge $today.AddDays(-$daysAgo) }
    foreach ($pkg in $recentPackages)
    {
      $day = Get-Date $pkg[2] -Format "yyyy-MM-dd"
      $dayHash[$day][$lang] = $dayHash[$day][$lang] + 1
      $total++
    }

    Write-Host "Total packages for $lang - $total"
  }

  $header = @("DATE")
  foreach($lang in $languages)
  {
    $header += $lang.ToUpper()
  }
  Write-Host ($header -join ",")

  foreach ($day in $dayHash.GetEnumerator())
  {
    $line = @($day)
    foreach($lang in $languages)
    {
      $line += $dayHash[$day][$lang]
    }
    Write-Host ($line -join ",")
  }
}

if ($MyInvocation.InvocationName -ne ".")
{
  Get-Package-Buckets $Languages $daysAgo
}
