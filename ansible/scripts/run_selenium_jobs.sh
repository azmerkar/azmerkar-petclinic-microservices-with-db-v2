PATH="$PATH:/usr/local/bin"
ansible-playbook -vvv --connection=local --inventory 127.0.0.1, --extra-vars "workspace=${WORKSPACE} master_public_ip=${GRAND_MASTER_PUBLIC_IP}" ./ansible/playbooks/pb_run_selenium_jobs.yaml
```
- Prepare a Jenkinsfile for `petclinic-nightly` builds and save it as `jenkinsfile-petclinic-nightly` under `jenkins` folder.

```groovy
pipeline {
    agent any
    environment {
        PATH=sh(script:"echo $PATH:/usr/local/bin", returnStdout:true).trim()
        APP_NAME="petclinic"
        APP_STACK_NAME="Callet-${APP_NAME}-app-${BUILD_NUMBER}"
        APP_REPO_NAME="claruswayset-repo/${APP_NAME}-app-dev"
        AWS_ACCOUNT_ID=sh(script:'export PATH="$PATH:/usr/local/bin" && aws sts get-caller-identity --query Account --output text', returnStdout:true).trim()
        AWS_REGION="us-east-1"
        ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
        CFN_KEYPAIR="call-${APP_NAME}-dev-${BUILD_NUMBER}.key"
        CFN_TEMPLATE="./infrastructure/dev-docker-swarm-infrastructure-cfn-template.yml"
        ANSIBLE_PRIVATE_KEY_FILE="${WORKSPACE}/${CFN_KEYPAIR}"
        ANSIBLE_HOST_KEY_CHECKING="False"
    }
    stages {
        stage('Create ECR Repo') {
            steps {
                echo "Creating ECR Repo for ${APP_NAME} app"
                sh """
                aws ecr create-repository \
                    --repository-name ${APP_REPO_NAME} \
                    --image-scanning-configuration scanOnPush=false \
                    --image-tag-mutability MUTABLE \
                    --region ${AWS_REGION}
                """
            }
        }
        stage('Package Application') {
            steps {
                echo 'Packaging the app into jars with maven'
                sh ". ./jenkins/package-with-maven-container.sh"
            }
        }
        stage('Prepare Tags for Docker Images') {
            steps {
                echo 'Preparing Tags for Docker Images'
                script {
                    MVN_VERSION=sh(script:'. ${WORKSPACE}/spring-petclinic-admin-server/target/maven-archiver/pom.properties && echo $version', returnStdout:true).trim()
                    env.IMAGE_TAG_ADMIN_SERVER="${ECR_REGISTRY}/${APP_REPO_NAME}:admin-server-v${MVN_VERSION}-b${BUILD_NUMBER}"
                    MVN_VERSION=sh(script:'. ${WORKSPACE}/spring-petclinic-api-gateway/target/maven-archiver/pom.properties && echo $version', returnStdout:true).trim()
                    env.IMAGE_TAG_API_GATEWAY="${ECR_REGISTRY}/${APP_REPO_NAME}:api-gateway-v${MVN_VERSION}-b${BUILD_NUMBER}"
                    MVN_VERSION=sh(script:'. ${WORKSPACE}/spring-petclinic-config-server/target/maven-archiver/pom.properties && echo $version', returnStdout:true).trim()
                    env.IMAGE_TAG_CONFIG_SERVER="${ECR_REGISTRY}/${APP_REPO_NAME}:config-server-v${MVN_VERSION}-b${BUILD_NUMBER}"
                    MVN_VERSION=sh(script:'. ${WORKSPACE}/spring-petclinic-customers-service/target/maven-archiver/pom.properties && echo $version', returnStdout:true).trim()
                    env.IMAGE_TAG_CUSTOMERS_SERVICE="${ECR_REGISTRY}/${APP_REPO_NAME}:customers-service-v${MVN_VERSION}-b${BUILD_NUMBER}"
                    MVN_VERSION=sh(script:'. ${WORKSPACE}/spring-petclinic-discovery-server/target/maven-archiver/pom.properties && echo $version', returnStdout:true).trim()
                    env.IMAGE_TAG_DISCOVERY_SERVER="${ECR_REGISTRY}/${APP_REPO_NAME}:discovery-server-v${MVN_VERSION}-b${BUILD_NUMBER}"
                    MVN_VERSION=sh(script:'. ${WORKSPACE}/spring-petclinic-hystrix-dashboard/target/maven-archiver/pom.properties && echo $version', returnStdout:true).trim()
                    env.IMAGE_TAG_HYSTRIX_DASHBOARD="${ECR_REGISTRY}/${APP_REPO_NAME}:hystrix-dashboard-v${MVN_VERSION}-b${BUILD_NUMBER}"
                    MVN_VERSION=sh(script:'. ${WORKSPACE}/spring-petclinic-vets-service/target/maven-archiver/pom.properties && echo $version', returnStdout:true).trim()
                    env.IMAGE_TAG_VETS_SERVICE="${ECR_REGISTRY}/${APP_REPO_NAME}:vets-service-v${MVN_VERSION}-b${BUILD_NUMBER}"
                    MVN_VERSION=sh(script:'. ${WORKSPACE}/spring-petclinic-visits-service/target/maven-archiver/pom.properties && echo $version', returnStdout:true).trim()
                    env.IMAGE_TAG_VISITS_SERVICE="${ECR_REGISTRY}/${APP_REPO_NAME}:visits-service-v${MVN_VERSION}-b${BUILD_NUMBER}"
                    env.IMAGE_TAG_GRAFANA_SERVICE="${ECR_REGISTRY}/${APP_REPO_NAME}:grafana-service"
                    env.IMAGE_TAG_PROMETHEUS_SERVICE="${ECR_REGISTRY}/${APP_REPO_NAME}:prometheus-service"
                }
            }
        }
        stage('Build App Docker Images') {
            steps {
                echo 'Building App Dev Images'
                sh ". ./jenkins/build-dev-docker-images-for-ecr.sh"
                sh 'docker image ls'
            }
        }
        stage('Push Images to ECR Repo') {
            steps {
                echo "Pushing ${APP_NAME} App Images to ECR Repo"
                sh ". ./jenkins/push-dev-docker-images-to-ecr.sh"
            }
        }
        stage('Create Key Pair for Ansible') {
            steps {
                echo "Creating Key Pair for ${APP_NAME} App"
                sh "aws ec2 create-key-pair --region ${AWS_REGION} --key-name ${CFN_KEYPAIR} --query KeyMaterial --output text > ${CFN_KEYPAIR}"
                sh "chmod 400 ${CFN_KEYPAIR}"
            }
        }
        stage('Create QA Automation Infrastructure') {
            steps {
                echo 'Creating QA Automation Infrastructure for Dev Environment with Cloudfomation'
                sh "aws cloudformation create-stack --region ${AWS_REGION} --stack-name ${APP_STACK_NAME} --capabilities CAPABILITY_IAM --template-body file://${CFN_TEMPLATE} --parameters ParameterKey=KeyPairName,ParameterValue=${CFN_KEYPAIR}"
                sh "aws cloudformation wait stack-create-complete --stack-name ${APP_STACK_NAME}" 
                script {
                    echo "Docker Grand Master is not UP and running yet."
                    env.id = sh(script: 'aws ec2 describe-instances --filters Name=tag-value,Values=grand-master Name=tag-value,Values=${APP_STACK_NAME} Name=instance-state-name,Values=running --query Reservations[*].Instances[*].[InstanceId] --output text',  returnStdout:true).trim()
                    sh 'aws ec2 wait instance-status-ok --instance-ids $id'
                }
            }
        }

        stage('Create Docker Swarm for QA Automation Build') {
            steps {
                echo "Setup Docker Swarm for QA Automation Build for ${APP_NAME} App"
                echo "Update dynamic environment"
                sh "sed -i 's/APP_STACK_NAME/${APP_STACK_NAME}/' ./ansible/inventory/dev_stack_dynamic_inventory_aws_ec2.yaml"
                echo "Swarm Setup for all nodes (instances)"
                sh "ansible-playbook -i ./ansible/inventory/dev_stack_dynamic_inventory_aws_ec2.yaml -b ./ansible/playbooks/pb_setup_for_all_docker_swarm_instances.yaml"
                echo "Swarm Setup for Grand Master node"
                sh "ansible-playbook -i ./ansible/inventory/dev_stack_dynamic_inventory_aws_ec2.yaml -b ./ansible/playbooks/pb_initialize_docker_swarm.yaml"
                echo "Swarm Setup for Other Managers nodes"
                sh "ansible-playbook -i ./ansible/inventory/dev_stack_dynamic_inventory_aws_ec2.yaml -b ./ansible/playbooks/pb_join_docker_swarm_managers.yaml"
                echo "Swarm Setup for Workers nodes"
                sh "ansible-playbook -i ./ansible/inventory/dev_stack_dynamic_inventory_aws_ec2.yaml -b ./ansible/playbooks/pb_join_docker_swarm_workers.yaml"
            }
        }

        stage('Deploy App on Docker Swarm'){
            steps {
                echo 'Deploying App on Swarm'
                sh 'envsubst < docker-compose-swarm-dev.yml > docker-compose-swarm-dev-tagged.yml'
                sh 'ansible-playbook -i ./ansible/inventory/dev_stack_dynamic_inventory_aws_ec2.yaml -b --extra-vars "workspace=${WORKSPACE} app_name=${APP_NAME} aws_region=${AWS_REGION} ecr_registry=${ECR_REGISTRY}" ./ansible/playbooks/pb_deploy_app_on_docker_swarm.yaml'
            }
        }

        stage('Test the Application Deployment'){
            steps {
                echo "Check if the ${APP_NAME} app is ready or not"
                script {
                    env.GRAND_MASTER_PUBLIC_IP = sh(script:"aws ec2 describe-instances --region ${AWS_REGION} --filters Name=tag-value,Values=grand-master Name=tag-value,Values=${APP_STACK_NAME} --query Reservations[*].Instances[*].[PublicIpAddress] --output text", returnStdout:true).trim()
                    while(true) {
                        try{
                            sh "curl -s ${GRAND_MASTER_PUBLIC_IP}:8080"
                            echo "${APP_NAME} app is successfully deployed."
                            break
                        }
                        catch(Exception){
                            echo "Could not connect to ${APP_NAME} app"
                            sleep(5)
                        }
                    }
                }
            }
        }

        stage('Run QA Automation Tests'){
            steps {
                echo "Run the Selenium Functional Test on QA Environment"
                sh 'ansible-playbook -vvv --connection=local --inventory 127.0.0.1, --extra-vars "workspace=${WORKSPACE} master_public_ip=${GRAND_MASTER_PUBLIC_IP}" ./ansible/playbooks/pb_run_selenium_jobs.yaml'
            }
        }
    }

    post {
        always {
            echo 'Deleting all local images'
            sh 'docker image prune -af'
            echo 'Delete the Image Repository on ECR'
            sh """
                aws ecr delete-repository \
                  --repository-name ${APP_REPO_NAME} \
                  --region ${AWS_REGION}\
                  --force
                """
            echo 'Tear down the Docker Swarm infrastructure using AWS CLI'
            sh "aws cloudformation delete-stack --region ${AWS_REGION} --stack-name ${APP_STACK_NAME}"
            echo "Delete existing key pair using AWS CLI"
            sh "aws ec2 delete-key-pair --region ${AWS_REGION} --key-name ${CFN_KEYPAIR}"
            sh "rm -rf ${CFN_KEYPAIR}"
        }
    }
}