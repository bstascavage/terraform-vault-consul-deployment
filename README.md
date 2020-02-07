# Veridian Dynamics - Vault Solution

## Introduction

Veridian Dynamics is in need of a secret management/authenication service at an enterprise level.  After initial kickoff and interviews, the following Phase 1 needs were determined:

* Upgrade VD's applications from static database credentials to a dynamic credential store.
* Add encryption/decryption support for applications in order to better secure data.
* Use a more confident authenication method, supporting both users and applications.
* Secure the initial installation.
* Segegration of policies and roles.
* Full audit logs.
* Multi-region configuration.

Given the determined requirements, we are confident in an initial POC within 2 billable days, which the exception of replication between multi-region clusters.  The following have been outlined as Phase 2 work, to be quantified as a potential week-long effort:

* Add DR cluster replication to us-west-2.
* Add Performance Replica in eu-central-1.
* Add Performance Replica in ap-southeast-1.
* User auth method via AD or another customer-chosen directory.
* Enable SSH secret engine for VM provisioning.
* Segergate regional data based on customer requirements via mount-paths.
* Test regional failover.
* Refactor legacy application code to remove credential storage files.

## Initial configuration

### Infrastructure Install

Initial operators will need to provision the cloud architecture for AWS, Consul, Bastion and applications via handoff provisioning tools.  For this handoff, we will be providing the customer `terraform` modules with the `aws` provider.  Infrastructure will adhere to agreed-upon security standards.

### Operator Initialization

The initial [operator](https://www.vaultproject.io/docs/commands/operator/init/) will need to setup the initial vault cluster while not exposing any new secrets.  To do that, the following procedures should be followed:

1. `vault operator init -recovery-pgp-keys="keybase:bstascavage,keybase:jgrose" -recovery-shares=2 -recovery-threshold=2`

    This will init the vault server and auto-seal the vault; the default installation will use KMS for auto-unsealing.  Two recovery keys have been generated and distributed to two unique users.  This is enforced via the unique user's keybase pgp keys.  Even if both keys end up in an attacker's possession, they would require two different admin's keybase keys to decrypt them.


2.  The operator needs to add their user auth method of choice.  Due to speed, `userpass` was chosen, but this should be configured to use AD.

3.  After an admin user is created, the operators need to create an admin policy.  This is provided by the consultants.  It can be created via `vault policy write admin admin.hcl`.  After it is created, it must be attached to an admin user in the chosen auth method.

4.  Finally, the root token needs to be revoked.  At this point, if root access is needed, we will need to recovery via the unique recovery keys in step #1.  This can be done via:

     `vault token revoke <root_token>`.

### Misc Cluster Configuration

* [Audit logging](https://www.vaultproject.io/docs/audit/syslog/) is enabled, forwarding all requests to vault to syslog: `vault audit enable syslog`.
* For Phase One, readonly, security, and operations users were provisioned via the `userpass` auth method.

### Dynamic Database Configuration

The [database](https://www.vaultproject.io/docs/secrets/databases/index.html) secrets engine was enabled to applications to get dynamic, rotated and leased temporary credentials.  This gives the application owners oppurtunity to limit blast radius', revoke any compromised keys, and control access to various databases.

1.  Enable the database secrets engine: 

    `vault secrets enable database`.
2.  For each database that needs to be managed, we can write a configuration for it: 

    `vault write database/config/erp-db plugin_name=mysql-database-plugin connection_url="{{username}}:{{password}}@t<db_host>:3306)/" allowed_roles="webapp-access" username="foo" password="foobarbaz"`.  
    (Note the `allowed_roles`, which will be set in step #3)

3.  We can create multiple roles, to be associated with various db configs in Vault.  Roles will contain the `sql` query for creating a user and assign the user configurable permissions on the database level. 

    `vault write database/roles/full-access db_name=erp-db creation_statements="CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}';GRANT SELECT ON *.* TO '{{name}}'@'%';" default_ttl="1h" max_ttl="24h"`

4.  Temporary credentials can be verified via: 

    `vault read mysql/creds/readonly`.

### IAM Auth Configuration

Given the high-density footprint that Veridian Dynamics has in Amazon Web Services, [IAM authentication](https://www.vaultproject.io/docs/auth/aws/) has been chosen as the application-level authentication method.  This allows the IAM role for a given EC2 or Lambda to be used to get the application's permission policy, allowing a secure mapping between the two.

1.  Enable the auth method: 

    `vault auth enable aws`.
2.  Ensure your AWS credentials are imported as ENV VARs on the Vault Server _and not perserved on disk_.  We will provide provisioning tools to support this.
3.  Configure the AWS provider.  The following command will source the credentials from their ENV vars: 

    `vault write -force auth/aws/config/client`.
4.  Create the policy for the webapp database.  This will define what permissions in Vault that any instance with the appropiate IAM role: 

    `vault policy write webapp-db webapp-db.hcl`.
5.  Create the Vault role for the IAM role, associating it with the appropriate policy: 

    `vault write auth/aws/role/webapp-role-iam uth_type=iam bound_iam_principal_arn="arn:aws:iam::130490850807:role/aSVx_A-instance-role20200206055316722900000001" policies=webapp-db ttl=24h`.

### Configuring the Vault Agent on the Application Server

Each application server will run a Vault agent, a deamon that will communicate back to the Vault server.  This agent can [auto-renew](https://www.vaultproject.io/docs/agent/autoauth/index.html) it's vault token and cache requests, both eliviating the responsibility for token renewal while reducing calls to the Vault API.  We will be using the application instances IAM role for authenication, so no Vault credentials will be stored or configured on the application servers.

We will provide ansible playbooks for installing and configuring the Vault agent.  The configuration is split into following [segments](https://www.vaultproject.io/docs/agent/):

* *vault* - The connection information for the Vault cluster.
* *auto_auth* - The IAM auto-auth configuration.  The `role` refers to the `auth/aws/role` you set in step #5 under the _IAM Auth Configuration_ section.
* *template* - This reads in a Consul Template File for your application.  Since the legacy application is a Flask app that gets it's database credentials from a flat configuration file, we need to write the temporary database credentials to said file.  The _template_ section populates this file with the database user and password, and constantly rewrites these as leases are renewed.
* *listener* - Lets the Vault agent listen on a port.  This allows any other application or user to use the instance's IP for RESTful Vault calls, or to point a local Vault CLI client at.  This way other vault clients can leverage this application auto-auth configuration.
* *cache* - The agent will cache requests and credentials for faster performance and decrease load.

The application's Vault Agent Config can be found in this repo at `vault-policies/vault-agent.hcl`.

We will provide the Vault Agent configuration file for your applications (configured by Ansible), along with template files for your flask application.  Once you start the Vault Agent, your `mysqldbcreds.json` will be written with your dynamic username and password, giving it transparent dynamic rotation.  This credential needs to be renewed once an hour and will be automatically revoked after 24 hours, to ensure that it is sort-lived and dynamic; the Vault agent will handle all of this fo ryour application natively.

Due to associating it's Vault policy with the IAM role, we can ensure that this application only has access to it's database dynamic credentials and nothing else, and ensure that no other application has access to this database credential as well.

### Configuring Encryption/Decryption of Data for Application

Since Veridian Dynamic's application works with sensitive data, we will configure it to use the [transit](https://www.vaultproject.io/docs/secrets/transit/index.html) secret engine.  This will allow the application to encrypt/decrypt data via the Vault Agent.  The following steps were created to enable the `transit` method:

1.  Enable the `transit` secret engine: 

    `vault secrets enable transit`.
2.  Create the `webapp-key` : 

    `vault write -f transit/keys/webapp-key`.
3.  Add the policies to the IAM role: 

    `vault write auth/aws/role/webapp-role-iam policies="webapp-db,webapp-encrypt,webapp-decrypt"`.

Once that is configured, the application's Vault Agent will have permissions to encrypt/decrypt with the `webapp-key`.  We have created a `vaulthook.sh` script to call the local agent for these procedures.  It can be found in the ansible playbook, and will automatically be deployed to your application server.

### Policy reference

The following Vault policies were created.  While all three are mapped to the application's IAM auth role, they can be used individually on other auth roles.  One example would be to have one application have the `webapp-encrypt` policy while a seperate application have the `webapp-decrypt` policy.

All policies can be found under the `vault-policies` directory.

* `admin` - Associated with an administror user in the `userpass` auth method.  Grants a wide range of `sudo ` priviledges for operations.
* `webapp-db` - Application access to the `database/creds/webapp-access` database credentials.
* `webapp-encrypt` - Application access to encrypt data with the `webapp-key`.
* `webapp-decrypt` - Application access to decrypt data with the `webapp-key`.