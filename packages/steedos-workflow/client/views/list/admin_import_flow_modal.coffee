Template.admin_import_flow_modal.helpers
	spaceId: ->
		return Session.get("spaceId");


Template.admin_import_flow_modal.events
	'click #import_flow_ok': (event)->
		formData = new FormData();

		formData.append('file-0', $("#importFlowFile")[0].files[0]);

		$.ajax
			type:"POST"
			url: Steedos.absoluteUrl("api/workflow/import/form?space=" + Session.get("spaceId"))
			processData: false
			contentType: false
			data: formData
			success: ()->
				toastr.success(t("import_flow_success"))
				Modal.hide("admin_import_flow_modal")
			error: (e)->
				toastr.error(t("import_flow_error"));
				console.log e

