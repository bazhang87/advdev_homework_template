#!/bin/bash
# Setup Jenkins Project
if [ "$#" -ne 3 ]; then
    echo "Usage:"
    echo "  $0 GUID REPO CLUSTER"
    echo "  Example: $0 wkha https://github.com/wkulhanek/ParksMap na39.openshift.opentlc.com"
    exit 1
fi

GUID=$1
REPO=$2
CLUSTER=$3
echo "Setting up Jenkins in project ${GUID}-jenkins from Git Repo ${REPO} for Cluster ${CLUSTER}"

# Code to set up the Jenkins project to execute the
# three pipelines.
# This will need to also build the custom Maven Slave Pod
# Image to be used in the pipelines.
# Finally the script needs to create three OpenShift Build
# Configurations in the Jenkins Project to build the
# three micro services. Expected name of the build configs:
# * mlbparks-pipeline
# * nationalparks-pipeline
# * parksmap-pipeline
# The build configurations need to have two environment variables to be passed to the Pipeline:
# * GUID: the GUID used in all the projects
# * CLUSTER: the base url of the cluster used (e.g. na39.openshift.opentlc.com)

node('maven') {
  try {
    def checkoutFolder = "/tmp/workspace/$env.JOB_NAME"

    def parksmapFolder = "$checkoutFolder/parksmap"
    def nationalparksFolder = "$checkoutFolder/nationalparks"
    def mlbparksFolder = "$checkoutFolder/mlbparks"

    def openshiftCicdProjectName = 'demo-cicd'

    def deploymentSuffix = ''
    def openshiftBaseProjectName = 'parksmap' + deploymentSuffix
    def openshiftDevProjectName = openshiftBaseProjectName + '-dev'
    def openshiftTestProjectName = openshiftBaseProjectName + '-test'
    def openshiftLiveProjectName = openshiftBaseProjectName + '-live'

    // get annotated version to make sure every build has a different one
    def appVersion = null
    def settingsFilename = null
    def mavenServerUrl = 'http://nexus.' + openshiftCicdProjectName + '.svc:8081/'
    def mavenMirrorUrl = mavenServerUrl + 'repository/maven-all-public/'
    def hostedMavenUrl = mavenServerUrl + 'repository/maven-releases/'

    def openshiftDockgerRegistryUrl = 'docker-registry.default.svc:5000/'
    def openshiftRegistryUrl = openshiftDockgerRegistryUrl + openshiftCicdProjectName + '/'
    def nexusUsername = 'admin'
    def nexusPassword = 'admin123'
    def sonarUrl = 'http://sonarqube.' + openshiftCicdProjectName + '.svc:9000'
    def sonarToken = '29c8f656bcf05f4f134273e697e856ed8536f83f'

    def dockerServerUrl = 'nexus.' + openshiftCicdProjectName + '.svc:8082/'
    def dockerRegistryUrl = dockerServerUrl + "$openshiftBaseProjectName-env/"
    def parksmapDockerRegistryUrl = null
    def nationalparksDockerRegistryUrl = null
    def mlbparksDockerRegistryUrl = null

    def parksmapBinaryArtifact = null
    def nationalparksBinaryArtifact = null
    def mlbparksBinaryArtifact = null

    def imageStreamsPreffix = "$env.JOB_NAME-$env.BUILD_NUMBER"

    // Start session with the service account jenkins which is the one configured by default for this builder
    openshift.withCluster() {
      stage('Checkout code') {
        // Set explicitely the checkout folder for further references
        dir(checkoutFolder) {
          // checkout the source code using the git information provided by the github webhook
          // This syntax allows to checkout also all annotated tags so get can get a different version each time.
          checkout([
              $class: 'GitSCM',
              branches: scm.branches,
              doGenerateSubmoduleConfigurations: scm.doGenerateSubmoduleConfigurations,
              extensions: [[$class: 'CloneOption', noTags: false, shallow: false, depth: 0, reference: '']],
              userRemoteConfigs: scm.userRemoteConfigs,
           ])
        }
      }
      stage('Create settings file') {
        settingsFilename = prepareEnvironment(checkoutFolder, mavenMirrorUrl, nexusUsername, nexusPassword)
      }
      stage('Get new version') {
        appVersion = getAppVersion(parksmapFolder)
      }
      stage("Parks Map - set v$appVersion") {
        setAppVersion(parksmapFolder, appVersion, settingsFilename)
        parksmapDockerRegistryUrl = dockerRegistryUrl + 'parksmap:' + appVersion
        nationalparksDockerRegistryUrl = dockerRegistryUrl + 'nationalparks:' + appVersion
        mlbparksDockerRegistryUrl = dockerRegistryUrl + 'mlbparks:' + appVersion
      }
      stage('Parks Map - Building') {
        build(parksmapFolder, settingsFilename)
        parksmapBinaryArtifact = getBinaryArtifact(parksmapFolder, 'jar')
      }
      stage('Parks Map - Running unit tests') {
        runUnitTests(parksmapFolder, settingsFilename, sonarUrl, sonarToken)
      }
      stage("National Parks - set v$appVersion") {
        setAppVersion(nationalparksFolder, appVersion, settingsFilename)
      }
      stage('National Parks - Building') {
        build(nationalparksFolder, settingsFilename)
        nationalparksBinaryArtifact = getBinaryArtifact(nationalparksFolder, 'jar')
      }
      stage('National Parks - Running unit tests') {
        runUnitTests(nationalparksFolder, settingsFilename, sonarUrl, sonarToken)
      }
      stage("MLB Parks - set v$appVersion") {
        setAppVersion(mlbparksFolder, appVersion, settingsFilename)
      }
      stage('MLB Parks - Building') {
        build(mlbparksFolder, settingsFilename)
        mlbparksBinaryArtifact = getBinaryArtifact(mlbparksFolder, 'war')
      }
      stage('MLB Parks - Running unit tests') {
        runUnitTests(mlbparksFolder, settingsFilename, sonarUrl, sonarToken)
      }

      stage('Parks Map - push jar to Nexus') {
        uploadArtifactToNexus(parksmapFolder, settingsFilename, hostedMavenUrl, parksmapBinaryArtifact)
      }
      stage('National Parls - push jar to Nexus') {
        uploadArtifactToNexus(nationalparksFolder, settingsFilename, hostedMavenUrl, nationalparksBinaryArtifact)
      }
      stage('MLB Parks - push war to Nexus') {
        uploadArtifactToNexus(mlbparksFolder, settingsFilename, hostedMavenUrl, mlbparksBinaryArtifact)
      }

      def parksmapImageStream = null
      def nationalparksImageStream = null
      def mlbparksImageStream = null

      openshift.withProject( openshiftCicdProjectName ) {
        try {
          stage('Parks Map - binary build') {
            def baseImage = getBaseImageName('jar')
            parksmapImageStream = "$imageStreamsPreffix-parksmap"
            doBinaryBuild(parksmapImageStream, baseImage, parksmapBinaryArtifact, appVersion)
          }
          stage('National Parls - binary build') {
            def baseImage = getBaseImageName('jar')
            nationalparksImageStream = "$imageStreamsPreffix-nationalparks"
            doBinaryBuild(nationalparksImageStream, baseImage, nationalparksBinaryArtifact, appVersion)
          }
          stage('MLB Parks - binary build') {
            def baseImage = getBaseImageName('war')
            mlbparksImageStream = "$imageStreamsPreffix-mlbparks"
            doBinaryBuild(mlbparksImageStream, baseImage, mlbparksBinaryArtifact, appVersion)
          }

          // Execute all three next commands in another node with support for skopeo
          node('skopeo') {
            stage('Parks Map - push docker image to Nexus') {
              uploadOcpImageToNexus(openshiftRegistryUrl + parksmapImageStream + ':' + appVersion, parksmapDockerRegistryUrl, "$nexusUsername:$nexusPassword")
            }
            stage('National Parls - push docker image to Nexus') {
              uploadOcpImageToNexus(openshiftRegistryUrl + nationalparksImageStream + ':' + appVersion, nationalparksDockerRegistryUrl, "$nexusUsername:$nexusPassword")
            }
            stage('MLB Parks - push docker image to Nexus') {
              uploadOcpImageToNexus(openshiftRegistryUrl + mlbparksImageStream + ':' + appVersion, mlbparksDockerRegistryUrl, "$nexusUsername:$nexusPassword")
            }
          }
        }
        finally {
          stage('Cleaning up local resources') {
            // Clean up local image streams and build configurations if they exist
            deleteObjects( "bc/$parksmapImageStream" )
            deleteObjects( "is/$parksmapImageStream" )
            deleteObjects( "bc/$nationalparksImageStream" )
            deleteObjects( "is/$nationalparksImageStream" )
            deleteObjects( "bc/$mlbparksImageStream" )
            deleteObjects( "is/$mlbparksImageStream" )
          }
        }
      }

      stage('Deploy to DEV') {
        // Ask for manual approval before going to DEV
        input message: "Promote v$appVersion to $openshiftDevProjectName (DEV)?", ok: "Promote"
        // Pull the image into DEV
        node('skopeo') {
          pullImageFromNexusToOcp(openshiftDockgerRegistryUrl + openshiftDevProjectName + '/parksmap:' + appVersion, parksmapDockerRegistryUrl, "$nexusUsername:$nexusPassword")
          pullImageFromNexusToOcp(openshiftDockgerRegistryUrl + openshiftDevProjectName + '/nationalparks:' + appVersion, nationalparksDockerRegistryUrl, "$nexusUsername:$nexusPassword")
          pullImageFromNexusToOcp(openshiftDockgerRegistryUrl + openshiftDevProjectName + '/mlbparks:' + appVersion, mlbparksDockerRegistryUrl, "$nexusUsername:$nexusPassword")
        }

        // Single deployment into DEV
        doSingleDeployment(openshiftDevProjectName, deploymentSuffix, openshiftDockgerRegistryUrl + openshiftDevProjectName + '/parksmap:' + appVersion, openshiftDockgerRegistryUrl + openshiftDevProjectName + '/nationalparks:' + appVersion, openshiftDockgerRegistryUrl + openshiftDevProjectName + '/mlbparks:' + appVersion)
      }

      stage('Running integration tests') {
        // Run integration tests in DEV
        openshift.withProject( openshiftDevProjectName ) {
          def parksmapUrl = 'http://' + openshift.selector('route', 'parksmap').object().spec.host
          def nationalparksUrl = 'http://' + openshift.selector('route', 'nationalparks').object().spec.host
          def mlbparksUrl = 'http://' + openshift.selector('route', 'mlbparks').object().spec.host
          runIntegrationTests(parksmapFolder, settingsFilename, sonarUrl, sonarToken, parksmapUrl, nationalparksUrl, mlbparksUrl)
        }
      }

      stage('Deploy to TEST') {
        // Ask for manual approval before going to TEST
        input message: "Promote v$appVersion to $openshiftTestProjectName (TEST)?", ok: "Promote"
        // Pull the image into TEST
        node('skopeo') {
          pullImageFromNexusToOcp(openshiftDockgerRegistryUrl + openshiftTestProjectName + '/parksmap:' + appVersion, parksmapDockerRegistryUrl, "$nexusUsername:$nexusPassword")
          pullImageFromNexusToOcp(openshiftDockgerRegistryUrl + openshiftTestProjectName + '/nationalparks:' + appVersion, nationalparksDockerRegistryUrl, "$nexusUsername:$nexusPassword")
          pullImageFromNexusToOcp(openshiftDockgerRegistryUrl + openshiftTestProjectName + '/mlbparks:' + appVersion, mlbparksDockerRegistryUrl, "$nexusUsername:$nexusPassword")
        }

        // Single deployment into TEST
        doSingleDeployment(openshiftTestProjectName, deploymentSuffix, openshiftDockgerRegistryUrl + openshiftTestProjectName + '/parksmap:' + appVersion, openshiftDockgerRegistryUrl + openshiftTestProjectName + '/nationalparks:' + appVersion, openshiftDockgerRegistryUrl + openshiftTestProjectName + '/mlbparks:' + appVersion)
      }

      stage('Running smoke tests') {
        // Run integration tests in TEST
        openshift.withProject( openshiftTestProjectName ) {
          def parksmapUrl = 'http://' + openshift.selector('route', 'parksmap').object().spec.host
          def nationalparksUrl = 'http://' + openshift.selector('route', 'nationalparks').object().spec.host
          def mlbparksUrl = 'http://' + openshift.selector('route', 'mlbparks').object().spec.host
          runIntegrationTests(parksmapFolder, settingsFilename, sonarUrl, sonarToken, parksmapUrl, nationalparksUrl, mlbparksUrl)
        }
      }

      stage('Deploy to LIVE') {
        // Ask for manual approval before going to LIVE
        input message: "Promote v$appVersion to $openshiftLiveProjectName (LIVE)?", ok: "Promote"
        // Pull the image into LIVE
        node('skopeo') {
          pullImageFromNexusToOcp(openshiftDockgerRegistryUrl + openshiftLiveProjectName + '/parksmap:' + appVersion, parksmapDockerRegistryUrl, "$nexusUsername:$nexusPassword")
          pullImageFromNexusToOcp(openshiftDockgerRegistryUrl + openshiftLiveProjectName + '/nationalparks:' + appVersion, nationalparksDockerRegistryUrl, "$nexusUsername:$nexusPassword")
          pullImageFromNexusToOcp(openshiftDockgerRegistryUrl + openshiftLiveProjectName + '/mlbparks:' + appVersion, mlbparksDockerRegistryUrl, "$nexusUsername:$nexusPassword")
        }

        // Blue/Green deployment into LIVE
        doBlueGreenDeployment(openshiftLiveProjectName, deploymentSuffix, openshiftDockgerRegistryUrl + openshiftLiveProjectName + '/parksmap:' + appVersion, openshiftDockgerRegistryUrl + openshiftLiveProjectName + '/nationalparks:' + appVersion, openshiftDockgerRegistryUrl + openshiftLiveProjectName + '/mlbparks:' + appVersion)
      }

      stage('Running smoke tests') {
        // Run integration tests in LIVE
        openshift.withProject( openshiftLiveProjectName ) {
          def parksmapUrl = 'http://' + openshift.selector('route', 'parksmap').object().spec.host
          def nationalparksUrl = 'http://' + openshift.selector('route', 'nationalparks').object().spec.host
          def mlbparksUrl = 'http://' + openshift.selector('route', 'mlbparks').object().spec.host
          runIntegrationTests(parksmapFolder, settingsFilename, sonarUrl, sonarToken, parksmapUrl, nationalparksUrl, mlbparksUrl)
        }
      }
    }
  }
  finally {
    // Place any notification to an external system we need to do in case of success or failure
  }
}

def getAppVersion(def appFolder) {
  // Gets the app version from the git repo, not the pom file or any other resources from the application itself.
  dir(appFolder) {
    def appVersion = sh script: "git describe 2> /dev/null || echo '0.0.0-no-tags'", returnStdout: true
    return appVersion.trim()
  }
}

def prepareEnvironment(def folder, def mavenMirrorUrl, def nexusUsername, def nexusPassword) {
  def filename = 'temp_settings.xml'
  def authSection = "<servers><server><id>nexus-maven-mirror</id><username>$nexusUsername</username><password>$nexusPassword</password></server></servers>"

  dir (folder) {
    sh """
      echo "<?xml version='1.0'?><settings>$authSection<mirrors><mirror><id>nexus-maven-mirror</id><name>Nexus Maven Mirror</name><url>$mavenMirrorUrl</url><mirrorOf>*</mirrorOf></mirror></mirrors></settings>" > $filename
    """
    return "$folder/$filename"
  }
}

def setAppVersion(def appFolder, def appVersion, def settingsFilename) {
  dir (appFolder) {
    sh """
      mvn -s $settingsFilename versions:set versions:commit -DnewVersion="$appVersion"
    """
  }
}

def build(def appFolder, def settingsFilename) {
  dir (appFolder) {
    sh """
      mvn -s $settingsFilename package -DskipTests
    """
  }
}

def runUnitTests(def appFolder, def settingsFilename, def sonarUrl, def sonarToken) {
  dir (appFolder) {
    try {
      sh """
        mvn -s $settingsFilename test
      """
    }
    finally {
      junit 'target/*reports/**/*.xml'
      sh """
        mvn -s $settingsFilename sonar:sonar -Dsonar.host.url=$sonarUrl -Dsonar.login=$sonarToken -Dsonar.jacoco.reportPaths=target/coverage-reports/jacoco-ut.exec
      """
      jacoco(execPattern: 'target/**/*.exec')
    }
  }
}

def runIntegrationTests(def appFolder, def settingsFilename, def sonarUrl, def sonarToken, def parksmapUrl, def nationalparksUrl, def mlbparksUrl) {
  dir (appFolder) {
    try {
    sh """
      mvn -s $settingsFilename clean verify -Dnationalparks.base.url="$nationalparksUrl" -Dmlbparks.base.url="$mlbparksUrl" -Dparksmap.base.url="$parksmapUrl"
    """
    }
    finally {
      // junit 'target/*reports/**/*.xml'
      sh """
        mvn -s $settingsFilename sonar:sonar -Dsonar.host.url=$sonarUrl -Dsonar.login=$sonarToken -Dsonar.jacoco.reportPaths=target/coverage-reports/jacoco-it.exec
      """
    }
  }
}

def getBinaryArtifact(def appFolder, def artifactExtension) {
  return sh(script: "ls $appFolder/target/*.$artifactExtension", returnStdout: true).trim()
}

def getBaseImageName(def artifactExtension) {
  return (artifactExtension == 'jar') ? 'openjdk18-openshift:1.3' : 'eap71-openshift:1.2'
}

def uploadArtifactToNexus(def appFolder, def settingsFilename, def repositoryUrl, def artifactFilename) {
  dir(appFolder) {
    sh """
      mvn -s $settingsFilename deploy:deploy-file -DgeneratePom=false -DpomFile=pom.xml -DrepositoryId=nexus-maven-mirror -Durl=$repositoryUrl -Dfile=$artifactFilename
    """
  }
}

def doBinaryBuild(def imageStream, def baseImage, def binaryArtifact, def appVersion) {
  // Creation of the build config
  openshift.newBuild("--allow-missing-imagestream-tags=true", "--binary=true", "-i '$baseImage'", "--name='$imageStream'", "--to='$imageStream:$appVersion'")
  // Start the binary build
  openshift.raw("start-build", "$imageStream", "--from-file='$binaryArtifact'", "--follow")
}

def uploadOcpImageToNexus(def openshiftStreamTag, def nexusImageStreamTag, def nexusCredentials) {
  def srcCredentials = 'jenkins:' + sh(script: "oc whoami -t", returnStdout: true).trim()
  sh """
    set +x
    skopeo copy --src-tls-verify=false --dest-tls-verify=false --src-creds=$srcCredentials --dest-creds='$nexusCredentials' docker://$openshiftStreamTag docker://$nexusImageStreamTag
  """
}

def deleteObjects( def selectorString ) {
  openshift.selector( selectorString ).withEach {
    it.delete( "--cascade=true", "--ignore-not-found=true", "--force=true", "--grace-period=0" )
  }
}

def pullImageFromNexusToOcp(def openshiftStreamTag, def nexusImageStreamTag, def nexusCredentials) {
  def destCredentials = 'jenkins:' + sh(script: "oc whoami -t", returnStdout: true).trim()
  sh """
    set +x
    skopeo copy --src-tls-verify=false --dest-tls-verify=false --src-creds='$nexusCredentials' --dest-creds=$destCredentials docker://$nexusImageStreamTag docker://$openshiftStreamTag
  """
}

def patchDeploymentAndRollout(def dcName, def containerName, def imageStreamTag) {
  openshift.raw("set", "triggers", "dc/$dcName", "--remove-all")
  openshift.raw("set", "image", "dc/$dcName", "$containerName=$imageStreamTag")

  def dc = openshift.selector('dc', dcName)
  // Set image
  dc.rollout().latest()
  def latestDeploymentVersion = dc.object().status.latestVersion
  def rc = openshift.selector('rc', "$dcName-${latestDeploymentVersion}")
  rc.untilEach(1){
      def rcMap = it.object()
      return (rcMap.status.replicas.equals(rcMap.status.readyReplicas))
  }
}

def doSingleDeployment(def projectName, def deploymentSuffix, def parksmapImageStramTag, def nationalparksImageStreamTag, def mlbparksImageStreamTag) {
  openshift.withProject( projectName ) {
    def parksmapDcName = "parksmap$deploymentSuffix"
    def nationalparksDcName = "nationalparks$deploymentSuffix"
    def mlbparksDcName = "mlbparks$deploymentSuffix"

    def parksmapContainerName = "parksmap"
    def nationalparksContainerName = "nationalparks"
    def mlbparksContainerName = "mlbparks"

    patchDeploymentAndRollout(nationalparksDcName, nationalparksContainerName, nationalparksImageStreamTag)
    patchDeploymentAndRollout(mlbparksDcName, mlbparksContainerName, mlbparksImageStreamTag)
    patchDeploymentAndRollout(parksmapDcName, parksmapContainerName, parksmapImageStramTag)
  }
}

def patchService(def serviceName, def targetDeployment) {
  def svc = openshift.selector('svc', serviceName).object()
  svc.spec.selector.deploymentConfig = targetDeployment
  openshift.apply(svc)
}

def patchRoute(def routeName, def serviceName) {
  def route = openshift.selector('route', routeName).object()
  route.spec.to.name = serviceName
  openshift.apply(route)
}

def doBlueGreenDeployment(def projectName, def deploymentSuffix, def parksmapImageStramTag, def nationalparksImageStreamTag, def mlbparksImageStreamTag) {
  openshift.withProject( projectName ) {
    //Use any of them because they will all changed at the same time and, if not, they will be sync in the next deployment.
    def svc = openshift.selector('svc', 'nationalparks' + deploymentSuffix).object()
    def targetDeployment = svc.spec.selector.deploymentConfig.endsWith('green') ? 'blue' : 'green'

    doSingleDeployment(projectName, "$deploymentSuffix-$targetDeployment", parksmapImageStramTag, nationalparksImageStreamTag, mlbparksImageStreamTag)
    patchService('nationalparks' + deploymentSuffix, 'nationalparks' + deploymentSuffix + '-' + targetDeployment)
    patchService('mlbparks' + deploymentSuffix, 'mlbparks' + deploymentSuffix + '-' + targetDeployment)
    patchRoute('parksmap' + deploymentSuffix, 'parksmap' + deploymentSuffix + '-' + targetDeployment)
  }
}

# To be Implemented by Student
