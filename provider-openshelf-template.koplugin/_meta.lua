-- Template for an OpenShelf provider plugin (PROVIDERS.md §8.2). Copy the
-- folder, rename it provider-openshelf-<id>.koplugin and edit the three files.
local _ = require("gettext")
return {
    name = "provider-openshelf-template",
    fullname = _("OpenShelf: Template Books"),
    description = _("Adds a small offline sample catalog to OpenShelf. Starting point for your own provider."),
}
