{{ define "autobench_dbt2" }}
#############################
#### Software definition ####
#############################

MYSQL_BIN_INSTALL_DIR=/srv/hops/mysql
BENCHMARK_TO_RUN="dbt2"

#########################################
#### Storage definition (empty here) ####
#########################################

#################################
#### MySQL Server definition ####
#################################

SERVER_HOST={{ .mySQLdHosts | quote }}
MYSQL_USER={{ .mysqlUsername | quote }}
MYSQL_PASSWORD={{ .mysqlPassword | quote }}
NDB_MULTI_CONNECTION={{ .MySQLdSlotsPerNode | quote }}

# PARAMETER                 EXAMPLE                         DESCRIPTION
#################################################################################################
# TASKSET                   "numactl"
# SERVER_HOST               "172.31.23.248;172.31.31.222"
# SERVER_PORT               "3316"
# SERVER_BIND               "0"
# SERVER_CPUS               "9-17,27-35"
# MYSQL_USER                "mysql"
# MYSQL_PASSWORD            "unsafe-password"
# NDB_MULTI_CONNECTION      "4"                             Number of slots in the config.ini per MySQL server
#                                                           Essentially how many connections we allow per IP with a
#                                                           MySQL server. This allows us to scale to up to 32 CPUs
#                                                           per MySQL VM/container/IP.

##############################
#### NDB node definitions ####
##############################

NDB_MGMD_NODES={{ .mgmdHosts | quote }}

# PARAMETER                EXAMPLE                          DESCRIPTION
#################################################################################################
# USE_SUPERSOCKET          "yes"
# USE_SHM                  "yes"
# NDBD_NODES               "172.31.23.248;172.31.31.222"
# NDB_MGMD_NODES           "172.31.23.248:3001"             The management connection string; a list of IPs of all the
#                                                           management servers
# NDB_TOTAL_MEMORY         "64G"
# NDBD_BIND                "0,1"
# NDBD_CPUS                "0-6,18-24"
# NDB_SPIN_METHOD          "DatabaseMachineSpinning"

##############################
#### Benchmark definition ####
##############################

DBT2_TIME="30"
DBT2_WAREHOUSES={{ .numWarehouses | quote }}
DBT2_DATA_DIR=/home/mysql/benchmarks/dbt2_data
{{ end }}
