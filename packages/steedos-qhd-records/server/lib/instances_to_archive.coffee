request = Npm.require('request')
path = Npm.require('path')
fs = Npm.require('fs')

logger = new Logger 'Records_QHD -> InstancesToArchive'

# spaces: Array 工作区ID
# contract_flows： Array 合同类流程
InstancesToArchive = (spaces, contract_flows, ins_ids) ->
	@spaces = spaces
	@contract_flows = contract_flows
	@ins_ids = ins_ids
	return

InstancesToArchive.success = (instance)->
	console.log("success, name is #{instance.name}, id is #{instance._id}")
	db.instances.direct.update({_id: instance._id}, {$set: {is_recorded: true}})

InstancesToArchive.failed = (instance, error)->
	console.log("failed, name is #{instance.name}, id is #{instance._id}. error: ")
	console.log error

#	获取非合同类的申请单：正常结束的(不包括取消申请、被驳回的申请单)
InstancesToArchive::getNonContractInstances = ()->
	query = {
		space: {$in: @spaces},
		flow: {$nin: @contract_flows},
		# is_archived字段被老归档接口占用，所以使用 is_recorded 字段判断是否归档
		$or: [
			{is_recorded: false},
			{is_recorded: {$exists: false}}
		],
		is_deleted: false,
		state: "completed",
		"values.record_need": "true",
		$or: [
			{final_decision: "approved"},
			{final_decision: {$exists: false}},
			{final_decision: ""}
		]
	}
	if @ins_ids
		query._id = {$in: @ins_ids}
	return db.instances.find(query, {fields: {_id: 1}}).fetch()


#	校验必填
_checkParameter = (formData) ->
	if !formData.fonds_name
		return false
	return true

# 按年度计算件数,生成电子文件号的最后组成
buildElectronicRecordCode = (formData) ->
	num = db.archive_wenshu.find({'year':formData?.year}).count() + 1
	strCount = (Array(6).join('0') + num).slice(-6)
	strElectronicRecordCode = formData?.fonds_identifier +
								formData?.archival_category_code +
								formData?.year + strCount
	return strElectronicRecordCode


# 整理档案表数据
_minxiInstanceData = (formData, instance) ->
	if !instance
		return
	dateFormat = "YYYY-MM-DD HH:mm:ss"

	formData.space = instance.space

	formData.owner = instance.submitter

	formData.created_by = instance.created_by

	formData.created = new Date()

	# 字段映射:表单字段对应到formData
	field_values = InstanceManager.handlerInstanceByFieldMap(instance)

	formData.applicant_name = field_values?.nigaorens
	formData.document_status = field_values?.guidangzhuangtai
	formData.archive_dept = field_values?.guidangbumen
	formData.applicant_organization_name=field_values?.nigaodanwei || field_values?.FILE_CODE_fzr
	formData.total_number_of_pages = field_values?.PAGE_COUNT
	formData.fonds_name = field_values?.fonds_name || field_values?.FONDSID
	formData.security_classification = field_values?.miji
	formData.document_type = field_values?.wenjianleixing
	formData.document_date = field_values?.wenjianriqi
	formData.archival_code = field_values?.wenjianzihao
	formData.author = field_values?.FILE_CODE_fzr
	formData.title = instance.name
#	formData.archive_retention_code

	# ...

	# 根据FONDSID查找全宗号
	fond = db.archive_fonds.findOne({'name':formData?.fonds_name})
	formData.fonds_identifier = fond?._id

	# 根据机构查找对应的类别号
	classification = db.archive_classification.findOne({'dept':/{formData?.FILING_DEPT}/})
	formData.category_code = classification?._id

	# 保管期限代码查找
	retention = db.archive_retention.findOne({'name':field_values?.baocunqixian})
	formData.retention_peroid = retention?._id

	# 根据保管期限,处理标志
	if retention?.years >= 10
		formData.produce_flag = "在档"
	else
		formData.produce_flag = "暂存"

	# 电子文件号，不生成，点击接收的时候才生成
	# formData.electronic_record_code = buildElectronicRecordCode formData
	
	# 归档日期
	formData.archive_date = moment(new Date()).format(dateFormat)

	# OA表单的ID，作为判断OA归档的标志
	formData.external_id = instance._id
	if instance?.related_instances
		related_archives = []
		instance.related_instances.forEach (related_instance) ->
			related_archive = db.archive_wenshu.findOne({'external_id':related_instance},{fields:{_id:1}})
			if related_archive
				related_archives.push related_archive?._id
		formData.related_archives = related_archives
	formData.is_received = false

	fieldNames = _.keys(formData)

	fieldNames.forEach (key)->
		fieldValue = formData[key]
		if _.isDate(fieldValue)
			fieldValue = moment(fieldValue).format(dateFormat)

		if _.isObject(fieldValue)
			fieldValue = fieldValue?.name

		if _.isArray(fieldValue) && fieldValue.length > 0 && _.isObject(fieldValue)
			fieldValue = fieldValue?.getProperty("name")?.join(",")

		if _.isArray(fieldValue)
			fieldValue = fieldValue?.join(",")

		if !fieldValue
			fieldValue = ''

	console.log("_minxiInstanceData end", instance._id)

	return formData



# 整理文件数据
_minxiAttachmentInfo = (instance, record_id) ->
	# 对象名
	object_name = RecordsQHD?.settings_records_qhd?.to_archive?.object_name
	parents = []
	spaceId = instance?.space
	# 查找 文件->归档
	files = cfs.instances.find({
		'metadata.instance': instance._id
	}).fetch()

	files.forEach (f)->
		console.log "==== f ===="
		console.log f?.copies?.instances?.name
		try
			newFile = new FS.File()
			cmsFileId = db.cms_files._makeNewID()
			console.log "cmsFileId", cmsFileId
			if !parents.includes(cmsFileId)
				parents.push cmsFileId
				db.cms_files.insert({
					_id: cmsFileId,
					parent: {
						o: object_name,
						ids: [record_id]
					},
					space: spaceId,
					versions: [],
					owner: f.metadata.owner,
					created_by: f.metadata.owner,
					modified_by: f.metadata.owner
				})

				# 未读到文件流？？？？？？
				newFile.attachData(
					f.createReadStream('instances'),
					{type: f.original.type},
					(err)->
						if err
							throw new Meteor.Error(err.error, err.reason)
						newFile.name f.name()
						newFile.size f.size()
						metadata = {
							owner: f.metadata.owner,
							owner_name: f.metadata?.owner_name,
							space: spaceId,
							record_id: record_id,
							object_name: object_name,
							parent: cmsFileId,
							current: f.metadata?.current
						}
						newFile.metadata = metadata
						fileObj = cfs.files.insert(newFile)
						if fileObj
							if f.metadata?.current == true
								db.cms_files.update(cmsFileId, {
									$set: {
											size: fileObj.size(),
											name: fileObj.name(),
											extention: fileObj.extension(),
										},
									$addToSet: {
											versions: fileObj._id
										}
									})
							else
								db.cms_files.update(cmsFileId, {
									$addToSet: {
											versions: fileObj._id
										}
									})
						
					)
		catch e
			logger.error "正文附件下载失败：#{f._id}. error: " + e


# 整理档案表数据
_minxiInstanceTraces = (auditList, instance, record_id) ->
	# 获取步骤状态文本
	getApproveStatusText = (approveJudge) ->
		locale = "zh-CN"
		#已结束的显示为核准/驳回/取消申请，并显示处理状态图标
		approveStatusText = undefined
		switch approveJudge
			when 'approved'
				# 已核准
				approveStatusText = TAPi18n.__('Instance State approved', {}, locale)
			when 'rejected'
				# 已驳回
				approveStatusText = TAPi18n.__('Instance State rejected', {}, locale)
			when 'terminated'
				# 已取消
				approveStatusText = TAPi18n.__('Instance State terminated', {}, locale)
			when 'reassigned'
				# 转签核
				approveStatusText = TAPi18n.__('Instance State reassigned', {}, locale)
			when 'relocated'
				# 重定位
				approveStatusText = TAPi18n.__('Instance State relocated', {}, locale)
			when 'retrieved'
				# 已取回
				approveStatusText = TAPi18n.__('Instance State retrieved', {}, locale)
			when 'returned'
				# 已退回
				approveStatusText = TAPi18n.__('Instance State returned', {}, locale)
			when 'readed'
				# 已阅
				approveStatusText = TAPi18n.__('Instance State readed', {}, locale)
			else
				approveStatusText = ''
				break
		return approveStatusText

	traces = instance?.traces

	traces.forEach (trace)->
		approves = trace?.approves || []
		approves.forEach (approve)->
			auditObj = {}
			auditObj.business_status = "计划任务"
			auditObj.business_activity = trace?.name
			auditObj.action_time = approve?.start_date
			auditObj.action_user = approve?.user
			auditObj.action_description = getApproveStatusText approve?.judge
			auditObj.action_administrative_records_id = record_id
			auditObj.instace_id = instance._id
			auditObj.space = instance.space
			auditObj.owner = approve?.user
			db.archive_audit.insert auditObj
	return auditList

InstancesToArchive.syncNonContractInstance = (instance, callback) ->
	#	表单数据
	formData = {}

	# 审计记录
	auditList = []

	_minxiInstanceData(formData, instance)

	if _checkParameter(formData)
		logger.debug("_sendContractInstance: #{instance._id}")
		# 添加到相应的档案表
		record_id = db.archive_wenshu.direct.insert(formData)
		if formData?.related_archives
			formData.related_archives.forEach (related_archive)->
				related_records = db.archive_wenshu.findOne({_id:related_archive},{fields:{related_archives:1}})
				console.log related_records
				if related_records?.related_archives.indexOf(record_id)<0
					related_records?.related_archives.push record_id
					db.archive_wenshu.direct.update({_id:related_archive},{$set:{related_archives:related_records?.related_archives}})

		_minxiAttachmentInfo(instance, record_id)

		# 处理审计记录
		_minxiInstanceTraces(auditList, instance, record_id)

		# InstancesToArchive.success instance
	else
		InstancesToArchive.failed instance, "立档单位 不能为空"


@Test = {}
# Test.run('WepcaSHkHrXXdEZ8D')
Test.run = (ins_id)->
	instance = db.instances.findOne({_id: ins_id})
	if instance
		InstancesToArchive.syncNonContractInstance instance

InstancesToArchive::syncNonContractInstances = () ->
	console.time("syncNonContractInstances")
	instances = @getNonContractInstances()
	that = @
	console.log "instances.length is #{instances.length}"
	instances.forEach (mini_ins)->
		instance = db.instances.findOne({_id: mini_ins._id})
		if instance
			console.log instance.name
			InstancesToArchive.syncNonContractInstance instance
	console.timeEnd("syncNonContractInstances")