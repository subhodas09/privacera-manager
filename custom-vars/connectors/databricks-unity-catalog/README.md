## How to Set up a Connector


1. Create a folder for connector setup:
    - Run the following command:
      ```
      mkdir instance1
      cd instance1
      ```

2. Copy the Connector YML file to the new instance directory (instance1 in this example):
    - Run the following command:
      ```
      cp ~/privacera/privacera-manager/config/sample-vars/vars.connector.databricks.unity.catalog.yml .
      ```

3. To add additional Connector instances, follow steps 1 and 2 again by creating another instance directory with a distinct name, for example, instance2 or instance3.

4. Follow public documentation to set up connector and its properties.

##     How to Set up Custom Properties for Connector

1. Create a folder named `custom` in the directory of connector-env folder.
    - For instance1:
      ```
      mkdir ~/privacera/privacera-manager/config/custom-vars/connectors/databricks-unity-catalog/instance1/custom
      ```

2. Create a file named `connector-custom.properties` under the custom directory:
    - This file is used to set `Custom Property` from the properties tables in public doc.
    - Run the following command:
      ```
      vi ~/privacera/privacera-manager/config/custom-vars/connectors/databricks-unity-catalog/instance1/custom/connector-custom.properties
      ```

3. Create a file named `connector-env-custom.sh` under the custom directory:
    - This file is used to set custom or override environment variables related to the connector before starting the process.
    - Run the following command:
      ```
      vi ~/privacera/privacera-manager/config/custom-vars/connectors/databricks-unity-catalog/instance1/custom/connector-env-custom.sh
      ```

4. Once you have added the custom properties to the files, continue setting up the Connector by using the command
    - For Regular Privacera Manager Setup
       ```
       cd ~/privacera/privacera-manager
       ./privacera-manager.sh update
       ```
    - For Helm Setup
       ```
       cd ~/privacera/privacera-manager 
       ./privacera-manager.sh setup
       sh pm_with_helm.sh upgrade
       ```