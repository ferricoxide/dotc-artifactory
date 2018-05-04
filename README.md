# DOTC-Artifactory

The dotc-artifactory project is a sub-project of the overarching DevOps Tool-Chain (DOTC) project. This project — and its peer projects — is designed to handle the automated deployment of common DevOps tool-chain services onto STIG-harderend, EL7-compatible Amazon EC2 instances and related AWS resources. The first part of this automation is comprised of CloudFormation (CFn) templates. Included in this project are the following templated activities:

* [Standalone EC2](Templates/make_artifactory-PRO_EC2-node.tmplt.json) instance
* [EFS-based](Templates/make_artifactory-PRO_EFS.tmplt.json) network-shares
* PostGreSQL [Amazon Relational Database Service](Templates/make_artifactory-PRO_RDS.tmplt.json)
* Network [Security Groups](Templates/make_artifactory_SGs.tmplt.json)
* [Application LoadBalancer](Templates/make_artifactory_ELBv2.tmplt.json) (a.k.a., "ELBv2" load-balancer)
* [Instance-role](Templates/make_artifactory-PRO_IAM-instance.tmplt.json) creation
* [Simple Storage Service](Templates/make_artifactory-PRO_S3-buckets.tmplt.json) for S3-hosted, persistent storage of backups. Includes lifecycle management an reporting extensions.
* [Parent Template](Templates/make_artifactory-PRO_parent-EFS.tmplt.json): drives all of the above stacks to create an end-to-end deployment.

The above currently do not support Artifactory Enterprise or use of AWS AutoScaling functionality. Both are pending features.

Additionally, automation-scripts are provided to automate the deployment of the Artifactory Server software onto the relevant EC2 instances. They have been tested on stand-alone Artifactory deployments but will be updated for use with AWS's AutoScaling service and Artifactory Enterprise as part of supporting those use-cases.

## Design Assumptions

These templates are intended for use within AWS VPCs. It is further expected that the deployed-to VPCs will be configured with public and private subnets. All Artifactory elements other than the Elastic LoadBalancer(s) are expected to be deployed into private subnets. The Elastic LoadBalancers provide transit of Internet-originating web UI requests to the the Artifactory node's web-based interface.

## Notes on Templates' Usage

It is generally expected that the use of the various, individual-service templates will be run via the "parent" template(s). The "parent" template allows for a kind of "one-button" deployment method where all the user needs to worry about is populating the template's fields and ensuring that CFn can find the child templates.

In order to use the "parent" template, it is recommended that the child templates be hosted in an S3 bucket separate from the one created for backups by this stack-set. The template-hosting bucket may be public or not. The files may be set to public or not. CFn typically has sufficient privileges to read the templates from a bucket without requiring the containing bucket or files being set public. Use of S3 for hosting eliminates the need to find other hosting-locations or sort out access-particulars of those hosting locations.

The EC2-related templates currently require that the scripts be anonymously `curl`able. The scripts can still be hosted in a non-public S3 bucket, but the scripts' file-ACLs will need to allow `public-read`. This may change in future releases — likely via an enhancement to the IAM template.

These templates do not include Route53 functionality. It is assumed that the requisite Route53 or other DNS alias will be configured separate from the instantiation of the public-facing ELB.

## Resultant Service Architecture

The templates and scripts act together to make standing up a new service quick and (reasonably) easy. Application-level configuration - beyond JDBC configuration - are not handled by these templates and scripts.

These templates and scripts are also designed to ensure that Artifactory data is persisted and backed up. This ensures that the Artifactory service can be quickly and easily reconstituted as necessary.
* As part of this design, the Artifactory artifact-repository is designed to be placed on an external, persistent network-attached storage. The supported storage option is currently limited to NFS (e.g. if using EFS). Some hooks for use with GlusterFS are included but not well-tested.
* Artifactory configuration data is expected to be hosted within an external PostGreSQL database (typically hosted via RDS).
* Backup cron-jobs for the Artifactory contents needs to be configured within Artifactory, itself. These tools include configuration of a "sweep to S3" cron job. If Artifactory is not configured to create backups, nothing will be swept to S3. This *will* adversely impact ability to recover or migrate Artifactory data.

## Closing Notes

* Ability to destroy and recreate at will, while retaining all configuration and hosted data, has been tested. It's expected that most such actions will happen via stack-update or autoscaling actions (manual, scheduled or reactive).  In the event that a stack-update results in two instances being "live" simultaneously, it will typically be necessary to restart the new instance after the pre-update instance terminates. This requirement is resultant Artifactory's built-in data-integrity protections.
* Due to a [bug](https://bugzilla.redhat.com/show_bug.cgi?id=1312002) in the systemd/nfs-client implementation in RHEL/CentOS 7, reboots of instances have a better than strong probability of hanging. If a hang occurs, it may be necessary to issue a force-shutdown to clear the hang (paired with a start if the goal was a reboot).
* The EC2 template runs [watchmaker](http://watchmaker.readthedocs.io/en/stable/) after the EC2 instance launches but before Artifactory has been installed. Watchmaker ensures that the resultant system is STIG-hardened. See the [Watchmaker document)(https://watchmaker.readthedocs.io/) for description of what Watchmaker does, how it does it and any additional, envionrment-specific fine-tuning that may be desired/needed.

![Build Status](https://travis-ci.org/plus3it/dote-artifactory.svg?branch=master)

