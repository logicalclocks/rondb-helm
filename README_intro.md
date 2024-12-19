## Usage

[Helm](https://helm.sh) must be installed to use the charts.  Please refer to
Helm's [documentation](https://helm.sh/docs) to get started.

Once Helm has been set up correctly, add the repo as follows:

```bash
helm repo add rondb https://logicalclocks.github.io/rondb-helm/
```

If you had already added this repo earlier, run `helm repo update` to retrieve
the latest versions of the packages.  You can then run `helm search repo
rondb` to see the charts.

To install the rondb chart:

```bash
helm install my-rondb rondb/rondb
```

To uninstall the chart:

```bash
helm delete my-rondb
```

## Values options
