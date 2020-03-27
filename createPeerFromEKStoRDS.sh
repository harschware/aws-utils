#!/bin/sh

set -e

#
# Set SCRIPT_PATH to be the path to this script
#
SCRIPT_PATH="${BASH_SOURCE[0]}";
if [ -h "${SCRIPT_PATH}" ]; then
    while [ -h "${SCRIPT_PATH}" ]
    do SCRIPT_PATH=`readlink "${SCRIPT_PATH}"`; done
fi
pushd . > /dev/null
cd `dirname ${SCRIPT_PATH}` > /dev/null
SCRIPT_PATH=`pwd`;
popd  > /dev/null
SCRIPT_NAME=$(basename "$0")



function usage {
   cat <<EOF
Usage: ${SCRIPT_NAME} [-h] [-g region] -e eksClusterName -r rdsEndpoint
   -g    AWS Region.  defaults to us-west-2
   -e    EKS Cluster Name e.g. logz-io-demo
   -r    RDS endpoint. e.g. tharsch-rds-dev1.cuw6ehs70cep.us-west-2.rds.amazonaws.com
EOF
}

AWS_REGION=us-west-2
while getopts ":hg:e:r:" opt; do
  case ${opt} in
    g)
      AWS_REGION=$OPTARG
      ;;
    e)
      EKS_CLUSTER_NAME=$OPTARG
      ;;
    r)
      RDS_ENDPOINT=$OPTARG
      ;;
    h) usage; exit;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done
shift $((OPTIND-1))

if [ -z ${EKS_CLUSTER_NAME} ]; then
  2>&1 echo "ERROR: Option 'e' is required"
  exit 1
fi
if [ -z ${RDS_ENDPOINT} ]; then
  2>&1 echo "ERROR: Option 'r' is required"
  exit 1
fi

EKS_VPC_ID=`aws eks describe-cluster --name ${EKS_CLUSTER_NAME} | jq -er .cluster.resourcesVpcConfig.vpcId`
echo EKS_VPC_ID=$EKS_VPC_ID

AWSCLI_RESPONSE=`aws rds describe-db-instances --query 'DBInstances[*].[DBInstanceArn,Engine,DBInstanceIdentifier,Endpoint.Address,DBSubnetGroup.VpcId,VpcSecurityGroups]' | jq -er ".[] | select( .[3] == \"${RDS_ENDPOINT}\" )"`

RDS_VPC_ID=`jq -r '.[4]' <<< "${AWSCLI_RESPONSE}"`
RDS_VPC_SECURITY_GROUP_ID=`jq -r '.[5][0].VpcSecurityGroupId' <<< "${AWSCLI_RESPONSE}"`
echo RDS_VPC_ID=$RDS_VPC_ID
echo RDS_VPC_SECURITY_GROUP_ID=$RDS_VPC_SECURITY_GROUP_ID

AWS_CLI_RESPONSE=`aws ec2 describe-vpc-peering-connections --query "VpcPeeringConnections[*]" | jq -r ".[] | select( .AccepterVpcInfo.VpcId == \"$RDS_VPC_ID\" and .RequesterVpcInfo.VpcId == \"$EKS_VPC_ID\" and .Status.Code != \"deleted\" ) | .VpcPeeringConnectionId + \",\" + .RequesterVpcInfo.CidrBlock"`

if [ -n "$AWS_CLI_RESPONSE" ]; then
   echo "VPC Peering Connection Found"
   IFS="," read VPC_PEERING_CONNECTION_ID EKS_CIDR_BLOCK <<<"$AWS_CLI_RESPONSE"
else
   echo "Create VPC Peering Connection"
   export AWSCLI_RESPONSE=`aws ec2 create-vpc-peering-connection \
      --peer-vpc-id   ${RDS_VPC_ID} \
      --vpc-id        ${EKS_VPC_ID} \
      --peer-region   ${AWS_REGION} | jq -re '.VpcPeeringConnection'`

   VPC_PEERING_CONNECTION_ID=`jq -r '.VpcPeeringConnectionId' <<<"${AWSCLI_RESPONSE}"`
   EKS_CIDR_BLOCK=`jq -r '.RequesterVpcInfo.CidrBlock' <<<"${AWSCLI_RESPONSE}"`

   aws ec2 create-tags \
      --resources $VPC_PEERING_CONNECTION_ID \
      --tags Key=Name,Value=VPC-Peer-EKS-to-RDS
fi

#
#  in the case that the VPC Peering connection has already been accepted, accept-vpc-peering-connection will return a success result as if it accepted the connection for first time 
#
RDS_CIDR_BLOCK=`aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id ${VPC_PEERING_CONNECTION_ID} | jq -er .VpcPeeringConnection.AccepterVpcInfo.CidrBlock`

echo "VPC_PEERING_CONNECTION_ID=$VPC_PEERING_CONNECTION_ID"
echo "EKS_CIDR_BLOCK=$EKS_CIDR_BLOCK"
echo "RDS_CIDR_BLOCK=$RDS_CIDR_BLOCK"

function validateOrCreateRoute() {
   local VPC_PEER_ID=$1 
   local ROUTE_TABLE_ID=$2
   local CIDR_BLOCK=$3

   echo "Validate or Create Route"

   if aws ec2 describe-route-tables --filters Name=route-table-id,Values="${ROUTE_TABLE_ID}" --query 'RouteTables[*].Routes' | jq -r ".[][] | select( .VpcPeeringConnectionId == \"$VPC_PEER_ID\" ) | .DestinationCidrBlock" | grep -q "${CIDR_BLOCK}"; then 
      echo "Route Valid"
   else
      echo "Create Route"
      aws ec2 create-route --vpc-peering-connection-id ${VPC_PEER_ID} --route-table-id ${ROUTE_TABLE_ID} --destination-cidr-block ${CIDR_BLOCK} > /dev/null
   fi
}

EKS_ROUTE_TABLE_ID=`aws ec2 describe-route-tables --filters Name="tag:aws:cloudformation:logical-id",Values="RouteTable" | jq -r '.RouteTables[0].RouteTableId'`
echo "EKS_ROUTE_TABLE_ID=$EKS_ROUTE_TABLE_ID"

validateOrCreateRoute "$VPC_PEERING_CONNECTION_ID" "$EKS_ROUTE_TABLE_ID" "${RDS_CIDR_BLOCK}"

RDS_ROUTE_TABLE_ID=`aws ec2 describe-route-tables --filters Name=vpc-id,Values=${RDS_VPC_ID} | jq -r '.RouteTables[0].RouteTableId'`
echo "RDS_ROUTE_TABLE_ID=$RDS_ROUTE_TABLE_ID"

validateOrCreateRoute "$VPC_PEERING_CONNECTION_ID" "$RDS_ROUTE_TABLE_ID" "${EKS_CIDR_BLOCK}"

function findSecurityGroupIngressRule() {
   local SECURITY_GROUP_ID=$1
   local CIDR_BLOCK=$2
   local PROTO=$3
   local PORT=$4

   aws ec2 describe-security-groups --group-ids "${SECURITY_GROUP_ID}" | jq -e ".SecurityGroups[].IpPermissions[] | select( .FromPort == $PORT and .ToPort == $PORT and .IpProtocol == \"$PROTO\" and .IpRanges[0].CidrIp == \"$CIDR_BLOCK\")" > /dev/null
}

if ! findSecurityGroupIngressRule "${RDS_VPC_SECURITY_GROUP_ID}" "${EKS_CIDR_BLOCK}" "tcp" "5432"; then
   echo "Create Security Group Ingress Rule for RDS"
   aws ec2 authorize-security-group-ingress --group-id ${RDS_VPC_SECURITY_GROUP_ID} --protocol tcp --port 5432 --cidr ${EKS_CIDR_BLOCK}
else
   echo "Security Group Ingress Rule for RDS found"
fi



