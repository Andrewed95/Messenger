// LI: Malicious files (quarantined media) display
import BlockIcon from "@mui/icons-material/Block";
import {
  Datagrid,
  DateField,
  List,
  ListProps,
  NumberField,
  Pagination,
  ResourceProps,
  TextField,
} from "react-admin";

const MaliciousFilesPagination = () => (
  <Pagination rowsPerPageOptions={[10, 25, 50, 100]} />
);

export const MaliciousFilesList = (props: ListProps) => {
  // LI: Fetch quarantined media from custom endpoint
  return (
    <List
      {...props}
      pagination={<MaliciousFilesPagination />}
      resource="malicious_files"
      sort={{ field: "created_ts", order: "DESC" }}
      perPage={25}
      bulkActionButtons={false}
    >
      <Datagrid>
        <TextField source="media_id" label="Media ID" />
        <TextField source="media_type" label="Type" />
        <NumberField
          source="media_length"
          label="Size (bytes)"
          options={{ useGrouping: true }}
        />
        <TextField source="upload_name" label="Original Name" />
        <DateField
          source="created_ts"
          label="Uploaded At"
          showTime
          options={{
            year: "numeric",
            month: "short",
            day: "numeric",
            hour: "2-digit",
            minute: "2-digit",
          }}
        />
        <TextField source="quarantined_by" label="Quarantined By" />
        <DateField
          source="last_access_ts"
          label="Last Accessed"
          showTime
          options={{
            year: "numeric",
            month: "short",
            day: "numeric",
            hour: "2-digit",
            minute: "2-digit",
          }}
        />
      </Datagrid>
    </List>
  );
};

const resource: ResourceProps = {
  name: "malicious_files",
  icon: BlockIcon,
  list: MaliciousFilesList,
};

export default resource;
