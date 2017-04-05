Template.admin_flows.helpers
	selector: ->
		return {space: Session.get("spaceId")};

Template.admin_flows.events
	'click #editFlow': (event) ->
		dataTable = $(event.target).closest('table').DataTable();
		rowData = dataTable.row(event.currentTarget.parentNode.parentNode).data();
		if (rowData)
			Session.set 'cmDoc', rowData
			$('.btn.record-types-edit').click();

	'click #importFlow': (event)->
		Modal.show("admin_import_flow_modal");